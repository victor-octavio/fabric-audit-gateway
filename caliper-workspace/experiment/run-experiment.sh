#!/usr/bin/env bash
# Runs a load experiment against the distributed network and analyzes it.
#
#   ./experiment/run-experiment.sh --ops "insert read" --tps "2 5 10 20 30 40" --duration 30 --reps 3 --name pilot
#
# For every repetition, operation and offered rate ("step") it
#   1. generates a Caliper benchmark: a short warm-up round, then the measured round (fixed rate, by duration)
#   2. samples CPU, memory, SD I/O, temperature, frequency and undervoltage on both Raspberry Pis and the Mac,
#      and logs the ICMP round trip to each Pi, while the step runs
#   3. runs Caliper (the workloads write one latency line per transaction)
#   4. waits for the Pis to cool down, then goes on to the next rate
# A repetition stops climbing the rate ladder once the system saturates. At the end analyze.py produces
# results/<name>/summary.md and the CSV files.
#
# Options: --ops "insert read update history mixed"   operations (default: insert)
#          --tps "2 5 10 ..."        offered rates in ascending order (default: 2 5 10 15 20 30 40)
#          --duration 30             seconds of the measured round (default 30)
#          --warmup 10               seconds of the warm-up round (default 10)
#          --reps 3                  repetitions (default 3)
#          --rep-start 2             number of the first repetition (to add repetitions to an existing experiment)
#          --workers 4               Caliper workers (default 4)
#          --arrivals poisson        arrival process: poisson (default, independent clients) or fixed
#          --name <id>               experiment name (default: exp-<timestamp>)
#          --no-stop                 keep climbing the ladder after saturation
#          --cooldown-max 120        longest cooldown wait in seconds (default 120)
#          --dry-run                 print the plan and exit
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$WS/../network/multi-org/inventory.env"

REP_START=1; OPS="insert"; TPS_LIST="2 5 10 15 20 30 40"; DURATION=30; WARMUP=10; REPS=3; WORKERS=4
ARRIVALS="poisson"; NAME=""; STOP_AT_SATURATION=1; COOLDOWN_MAX=120; COOLDOWN_MARGIN=4; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ops) OPS="$2"; shift 2 ;;
    --tps) TPS_LIST="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --reps) REPS="$2"; shift 2 ;;
    --rep-start) REP_START="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --arrivals) ARRIVALS="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --no-stop) STOP_AT_SATURATION=0; shift ;;
    --cooldown-max) COOLDOWN_MAX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

# A sleeping laptop freezes the load generator and the connections to the Pis for minutes and ruins the step.
# caffeinate keeps the machine awake for as long as this script runs (keep it on AC power with the lid open).
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -dimsu -w $$ > /dev/null 2>&1 &
fi

EXP_NAME="${NAME:-exp-$(date +%Y%m%d-%H%M%S)}"
EXP="$WS/results/$EXP_NAME"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

node_host() { case "$1" in pi3) echo "$PI3_HOST" ;; pi5) echo "$PI5_HOST" ;; esac; }
node_user() { case "$1" in pi3) echo "$PI3_USER" ;; pi5) echo "$PI5_USER" ;; esac; }
pi() { local node="$1"; shift; ssh "${SSH_OPTS[@]}" "$(node_user "$node")@$(node_host "$node")" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

n_steps=0; for _ in $OPS; do for _ in $TPS_LIST; do n_steps=$((n_steps + 1)); done; done
log "experiment $EXP_NAME: ops [$OPS], rates [$TPS_LIST] TPS, ${DURATION}s per step (+${WARMUP}s warm-up), $REPS repetition(s), $WORKERS workers"
log "up to $((n_steps * REPS)) steps, roughly $((n_steps * REPS * (DURATION + WARMUP + 45) / 60)) minutes (less if the ladder stops at saturation)"
[ "$DRY_RUN" = 1 ] && exit 0

# ------------------------------------------------------------------ preflight

preflight() {
  local node bad=0 off uv
  for node in pi3 pi5; do
    if ! pi "$node" true 2>/dev/null; then log "ERROR: $node unreachable"; bad=1; continue; fi
    off=$(pi "$node" "chronyc tracking 2>/dev/null | awk '/System time/{printf \"%d\", \$4*1000}'")
    if [ -z "$off" ] || [ "$off" -gt 50 ]; then log "ERROR: $node clock offset ${off:-unknown} ms (limit 50 ms)"; bad=1; fi
    if ! pi "$node" "docker ps --format '{{.Names}}' | grep -q '^peer0\\.'"; then log "ERROR: no peer container running on $node"; bad=1; fi
    uv=$(pi "$node" "journalctl -b -k --no-pager | grep -ciE 'under-?voltage'")
    log "$node: clock offset ${off:-?} ms, undervoltage messages since boot: ${uv:-?}"
  done
  for n in peer0.org1.example.com peer0.org2.example.com peer0.org3.example.com; do
    python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1])' "$n" 2>/dev/null || { log "ERROR: $n does not resolve (network.sh hosts apply)"; bad=1; }
  done
  [ "$bad" = 0 ] || exit 1
}

pi_temp() { pi "$1" "awk '{printf \"%d\", \$1/1000}' /sys/class/thermal/thermal_zone0/temp" 2>/dev/null; }
pi_uv_count() { pi "$1" "journalctl -b -k --no-pager | grep -ciE 'under-?voltage'" 2>/dev/null; }

# ------------------------------------------------------------------ sampling

SAMPLER_PIDS=()
start_sampling() {
  local dir="$1" node
  SAMPLER_PIDS=()
  for node in pi3 pi5; do
    ssh "${SSH_OPTS[@]}" "$(node_user "$node")@$(node_host "$node")" 'bash -s -- 1 900' < "$HERE/sampler.sh" > "$dir/samples-$node.csv" 2>/dev/null &
    SAMPLER_PIDS+=($!)
    ping -i 0.5 -c 1800 "$(node_host "$node")" > "$dir/rtt-$node.txt" 2>&1 &
    SAMPLER_PIDS+=($!)
  done
  bash "$HERE/sampler-mac.sh" 900 > "$dir/samples-mac.csv" 2>/dev/null &
  SAMPLER_PIDS+=($!)
}

stop_sampling() {
  local p
  for p in "${SAMPLER_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  for p in "${SAMPLER_PIDS[@]}"; do wait "$p" 2>/dev/null; done
  SAMPLER_PIDS=()
}
trap 'stop_sampling; exit 130' INT TERM

# ------------------------------------------------------------------ cooldown

BASE_PI3=0; BASE_PI5=0
measure_baseline() {
  local a b t
  a=0; b=0
  for _ in 1 2 3; do
    t=$(pi_temp pi3); [ "${t:-0}" -gt "$a" ] && a=$t
    t=$(pi_temp pi5); [ "${t:-0}" -gt "$b" ] && b=$t
    sleep 2
  done
  BASE_PI3=$a; BASE_PI5=$b
  log "idle temperature baseline: pi3 ${BASE_PI3} C, pi5 ${BASE_PI5} C (cooldown target: baseline + ${COOLDOWN_MARGIN})"
}

cooldown() {
  local start t3 t5
  start=$(date +%s)
  while :; do
    t3=$(pi_temp pi3); t5=$(pi_temp pi5)
    if [ "${t3:-999}" -le $((BASE_PI3 + COOLDOWN_MARGIN)) ] && [ "${t5:-999}" -le $((BASE_PI5 + COOLDOWN_MARGIN)) ]; then break; fi
    if [ $(( $(date +%s) - start )) -ge "$COOLDOWN_MAX" ]; then log "cooldown limit reached (pi3 ${t3} C, pi5 ${t5} C)"; break; fi
    sleep 5
  done
  sleep 3
}

# ------------------------------------------------------------------ one step

# Prints "valid saturated" for the finished step.
run_step() {
  local rep="$1" op="$2" tps="$3"
  local dir="$EXP/rep$rep/$op-$tps" rel
  rm -rf "$dir"   # never mix transactions of an earlier attempt into this step
  mkdir -p "$dir"
  rel="results/$EXP_NAME/rep$rep/$op-$tps/benchmark.yaml"

  python3 "$HERE/gen_config.py" --op "$op" --tps "$tps" --duration "$DURATION" --workers "$WORKERS" --arrivals "$ARRIVALS" \
    --warmup-duration "$WARMUP" --out "$dir/benchmark.yaml" --meta "$dir/meta.json" || return 2

  local uv3 uv5 uv3b uv5b
  uv3=$(pi_uv_count pi3); uv5=$(pi_uv_count pi5)
  start_sampling "$dir"
  sleep 2
  ( cd "$WS" && BENCH_RESULTS_DIR="$dir" npx caliper launch manager \
      --caliper-workspace ./ --caliper-networkconfig networkConfig.yaml --caliper-benchconfig "$rel" \
      --caliper-flow-only-test --caliper-fabric-gateway-enabled \
      --caliper-report-path "results/$EXP_NAME/rep$rep/$op-$tps/report.html" ) > "$dir/caliper.log" 2>&1
  local rc=$?
  sleep 3
  stop_sampling
  uv3b=$(pi_uv_count pi3); uv5b=$(pi_uv_count pi5)
  printf '{"pi3": {"before": %s, "after": %s}, "pi5": {"before": %s, "after": %s}}\n' \
    "${uv3:-0}" "${uv3b:-0}" "${uv5:-0}" "${uv5b:-0}" > "$dir/kernel-uv.json"

  python3 "$HERE/analyze.py" --step "$dir" > "$dir/step.json" 2>/dev/null
  python3 - "$dir/step.json" "$tps" "$rc" <<'EOF'
import json, sys
path, tps, rc = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
try:
    s = json.load(open(path))
except Exception:
    s = None
if not s or s.get("status") != "ok":
    print(f"nodata caliper_rc={rc}")
else:
    print("{} {} thr={:.1f} p50={:.0f}ms p95={:.0f}ms fail={:.1f}% {}".format(
        "valid" if s["valid"] else "INVALID", ("SEVERE-SATURATED" if s.get("severe") else "SATURATED") if s["saturated"] else "ok", s["throughput"], s["lat_p50"],
        s["lat_p95"], s["fail_pct"], "; ".join(s["saturation_reasons"] + s["reasons"] + s["warnings"])))
EOF
}

# ------------------------------------------------------------------ main

preflight
mkdir -p "$EXP"
"$HERE/collect-env.sh" "$EXP/environment.md" > /dev/null
{ echo "ops=$OPS"; echo "tps=$TPS_LIST"; echo "duration=$DURATION"; echo "warmup=$WARMUP"; echo "reps=$REPS"
  echo "workers=$WORKERS"; echo "arrivals=$ARRIVALS"; echo "started=$(date -u +%FT%TZ)"; } > "$EXP/params.txt"
measure_baseline

consecutive_failures=0
for rep in $(seq "$REP_START" $((REP_START + REPS - 1))); do
  for op in $OPS; do
    log "---- repetition $rep (of $REP_START..$((REP_START + REPS - 1))), $op"
    consecutive_sat=0
    for tps in $TPS_LIST; do
      result=$(run_step "$rep" "$op" "$tps")
      log "rep$rep $op @ ${tps} TPS: $result"
      case "$result" in
        INVALID*)
          # undervoltage, a stalled host or a network blackout: not a property of the system, so measure again
          log "step invalid, repeating it once"
          cooldown
          result=$(run_step "$rep" "$op" "$tps")
          log "rep$rep $op @ ${tps} TPS (second attempt): $result"
          ;;
      esac
      case "$result" in
        nodata*) consecutive_failures=$((consecutive_failures + 1)) ;;
        *) consecutive_failures=0 ;;
      esac
      if [ "$consecutive_failures" -ge 2 ]; then
        log "two steps in a row produced no data: stopping (see $EXP/rep$rep/$op-$tps/caliper.log)"
        python3 "$HERE/analyze.py" "$EXP" > /dev/null 2>&1
        exit 1
      fi
      if [ "$STOP_AT_SATURATION" = 1 ]; then
        # one saturated step can be noise: stop after two in a row, or at once when it is severe
        case "$result" in
          INVALID*) consecutive_sat=0 ;;
          *SEVERE-SATURATED*) log "severe saturation, ending the ladder for this repetition"; cooldown; break ;;
          *SATURATED*) consecutive_sat=$((consecutive_sat + 1)) ;;
          *) consecutive_sat=0 ;;
        esac
        if [ "$consecutive_sat" -ge 2 ]; then log "saturation confirmed by two steps in a row, ending the ladder for this repetition"; cooldown; break; fi
      fi
      cooldown
    done
  done
done

echo "finished=$(date -u +%FT%TZ)" >> "$EXP/params.txt"
log "analyzing"
python3 "$HERE/analyze.py" "$EXP"
log "results in $EXP (summary.md, summary.csv, steps.csv)"
