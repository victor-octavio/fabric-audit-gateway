#!/usr/bin/env python3
"""Analyzes an experiment directory produced by run-experiment.sh.

results/<experiment>/rep<k>/<op>-<tps>/
    meta.json                  which rounds ran (warm-up and measured)
    latencies-w*.csv           one line per transaction, written by the workloads
    samples-pi3.csv, ...       resource samples taken during the step
    kernel-uv.json             undervoltage messages in the kernel log before/after the step

For every step it computes throughput, latency percentiles and the load on each node, decides whether the
step is valid (undervoltage invalidates it), finds the saturation point of each repetition and aggregates
the repetitions with a 95% confidence interval. Standard library only.
"""
import argparse
import csv
import glob
import json
import math
import os
import statistics
import sys

# two-sided 95% Student t critical values by degrees of freedom
T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
       15: 2.131, 20: 2.086, 30: 2.042}
PI_NODES = ("pi3", "pi5")
THROTTLE_WARN_FRACTION = 0.10
# A step is saturated when any of these holds. Throughput is NOT one of them: with Poisson arrivals a 30 s step at a
# low rate holds only ~60 transactions (a count varying by +-13%), completions arrive in bursts (one per block) and
# the time until the LAST completion includes the latency tail, so throughput reads well below the offered rate
# without anything being wrong. It is still reported. The sharp signals are failures and the latency trend inside
# the round: a stable system has the same latency at the end as at the start, a saturated one queues requests and
# the latency keeps climbing.
SATURATION_FAIL_PCT = 1.0
SATURATION_TREND_RATIO = 2.0         # median latency of the last quarter / of the first quarter
SATURATION_TREND_MIN_MS = 1000       # ... and at least this much slower in absolute terms (batch-timeout noise is below)
SATURATION_TREND_MIN_TX = 60         # fewer transactions make the quartile medians too noisy
SEVERE_FAIL_PCT = 5.0
SEVERE_TREND_RATIO = 4.0
SATURATION_P95_FACTOR = 3.0          # p95 above this many times the lowest step's p95 (checked across steps)
JITTER_RTT_P95_MS = 250             # warning thresholds for a noisy network link
JITTER_RTT_MAX_MS = 1500
STALL_RTT_MS = 5000                  # a ping answered later than this means the host or the network froze
STALL_SAMPLER_GAP_S = 8              # the Mac sampler takes ~1.4 s per sample
GENERATOR_LIMITED_RATIO = 0.85       # sent / offered below this, with enough transactions: the load generator is the limit


def percentile(sorted_values, p):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return sorted_values[int(k)]
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


def t_crit(df):
    if df < 1:
        return float("nan")
    for key in sorted(T95):
        if df <= key:
            return T95[key]
    return 1.96


def mean_ci(values):
    """(mean, standard deviation, half width of the 95% confidence interval)"""
    values = [v for v in values if v == v]
    if not values:
        return float("nan"), float("nan"), float("nan")
    m = statistics.fmean(values)
    if len(values) < 2:
        return m, float("nan"), float("nan")
    sd = statistics.stdev(values)
    return m, sd, t_crit(len(values) - 1) * sd / math.sqrt(len(values))


def read_csv(path):
    rows = []
    try:
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                if None in row.values() or None in row:   # truncated last line
                    continue
                rows.append(row)
    except FileNotFoundError:
        pass
    return rows


def load_transactions(step_dir):
    txs = []
    for path in glob.glob(os.path.join(step_dir, "latencies-w*.csv")):
        for r in read_csv(path):
            try:
                txs.append((int(r["round"]), int(r["start_ms"]), int(r["latency_ms"]), int(r["ok"])))
            except (KeyError, ValueError):
                continue
    return txs


def window_samples(rows, t0, t1, margin_ms=1000):
    out = []
    for r in rows:
        try:
            ts = int(r["ts_ms"])
        except (KeyError, ValueError):
            continue
        if t0 - margin_ms <= ts <= t1 + margin_ms:
            out.append(r)
    return out


def fnum(rows, key, default=float("nan")):
    vals = []
    for r in rows:
        try:
            vals.append(float(r[key]))
        except (KeyError, ValueError):
            pass
    return vals if vals else [default]


def rtt_stats(path):
    """avg / p95 / max of the ICMP round trips (ms) logged by ping during the step"""
    import re
    vals = []
    try:
        with open(path) as f:
            for line in f:
                m = re.search(r"time=([0-9.]+) ms", line)
                if m:
                    vals.append(float(m.group(1)))
    except FileNotFoundError:
        pass
    if not vals:
        return None
    vals.sort()
    return statistics.fmean(vals), percentile(vals, 95), vals[-1]


def analyze_step(step_dir, trim_s):
    meta_path = os.path.join(step_dir, "meta.json")
    if not os.path.exists(meta_path):
        return None
    meta = json.load(open(meta_path))
    measured = next(r for r in meta["rounds"] if not r["warmup"])
    step = {"dir": step_dir, "op": meta["op"], "tps": meta["tps"], "duration": meta["duration"],
            "workers": meta["workers"], "rep": os.path.basename(os.path.dirname(step_dir)),
            "valid": True, "reasons": [], "warnings": []}

    txs = [t for t in load_transactions(step_dir) if t[0] == measured["index"]]
    if not txs:
        step.update(status="no-data", valid=False, reasons=["no transactions recorded"])
        return step
    step["status"] = "ok"

    starts = [t[1] for t in txs]
    t_first, t_last_start = min(starts), max(starts)
    t_end = max(t[1] + t[2] for t in txs)
    span_start = max((t_last_start - t_first) / 1000.0, 1e-9)
    span_total = max((t_end - t_first) / 1000.0, 1e-9)

    # steady state: ignore the first and last seconds of the round
    lo, hi = t_first + trim_s * 1000, t_last_start - trim_s * 1000
    steady = [t for t in txs if lo <= t[1] <= hi] if hi > lo else txs
    ok_all = [t for t in txs if t[3]]
    ok_steady = [t for t in steady if t[3]]
    lat = sorted(t[2] for t in ok_steady)

    # Throughput as Caliper defines it: successes / time until the last completion. throughput_steady counts
    # completions inside the trimmed window; it is noisy because completions come in bursts, one per block.
    steady_len = (hi - lo) / 1000.0
    throughput_steady = (sum(1 for t in ok_all if lo <= t[1] + t[2] <= hi) / steady_len
                         if hi > lo and steady_len >= 5 else float("nan"))

    # latency trend: does the system keep up for the whole round?
    by_start = sorted(ok_all, key=lambda t: t[1])
    trend, first_med, last_med = float("nan"), float("nan"), float("nan")
    if len(by_start) >= SATURATION_TREND_MIN_TX:
        q = max(10, len(by_start) // 4)
        first_med = statistics.median(t[2] for t in by_start[:q])
        last_med = statistics.median(t[2] for t in by_start[-q:])
        trend = last_med / first_med if first_med > 0 else float("nan")

    step.update(
        tx_total=len(txs), tx_ok=len(ok_all), fail_pct=100.0 * (len(txs) - len(ok_all)) / len(txs),
        send_tps=len(txs) / span_start, throughput=len(ok_all) / span_total, throughput_steady=throughput_steady,
        lat_trend=trend, lat_first_q_ms=first_med, lat_last_q_ms=last_med,
        lat_mean=statistics.fmean(lat) if lat else float("nan"),
        lat_sd=statistics.stdev(lat) if len(lat) > 1 else float("nan"),
        lat_min=lat[0] if lat else float("nan"), lat_p50=percentile(lat, 50), lat_p90=percentile(lat, 90),
        lat_p95=percentile(lat, 95), lat_p99=percentile(lat, 99), lat_max=lat[-1] if lat else float("nan"),
        window_s=span_total, t0=t_first, t1=t_end)

    sat = []
    if step["fail_pct"] > SATURATION_FAIL_PCT:
        sat.append(f"{step['fail_pct']:.1f}% failures")
    if trend == trend and trend > SATURATION_TREND_RATIO and (last_med - first_med) > SATURATION_TREND_MIN_MS:
        sat.append(f"latency grew {first_med:.0f} -> {last_med:.0f} ms during the round")
    step["saturated"], step["saturation_reasons"] = bool(sat), sat
    step["severe"] = bool(step["fail_pct"] > SEVERE_FAIL_PCT
                          or (trend == trend and trend > SEVERE_TREND_RATIO and (last_med - first_med) > 2 * SATURATION_TREND_MIN_MS))
    if len(txs) >= 200 and step["send_tps"] < GENERATOR_LIMITED_RATIO * meta["tps"]:
        step["warnings"].append(f"load generator sent {step['send_tps']:.1f} TPS of {meta['tps']} offered")
    # With Poisson arrivals the number of transactions has standard deviation sqrt(expected); far outside that range
    # the generator did not produce the configured load, and the step must be read with the TRUE sent rate.
    expected_tx = meta["tps"] * meta["duration"]
    if meta.get("arrivals", "poisson") == "poisson" and abs(len(txs) - expected_tx) > 4 * math.sqrt(expected_tx):
        step["warnings"].append(f"sent {len(txs)} transactions, {expected_tx:.0f} expected (+-{4 * math.sqrt(expected_tx):.0f}): "
                                f"actual rate {step['send_tps']:.1f} TPS, not {meta['tps']}")

    for node in PI_NODES:
        rows = read_csv(os.path.join(step_dir, f"samples-{node}.csv"))
        w = window_samples(rows, t_first, t_end)
        if len(w) < max(3, 0.5 * span_total):
            step["valid"] = False
            step["reasons"].append(f"{node}: resource samples missing")
            w = w or []
        if not w:
            continue
        cpu, thr, uv = fnum(w, "cpu_pct"), fnum(w, "throttled"), fnum(w, "uv_alarm")
        step[f"{node}_cpu_mean"] = statistics.fmean(cpu)
        step[f"{node}_cpu_max"] = max(cpu)
        step[f"{node}_load_max"] = max(fnum(w, "load1"))
        step[f"{node}_mem_min_mb"] = min(fnum(w, "mem_avail_mb"))
        step[f"{node}_swap_max_mb"] = max(fnum(w, "swap_used_mb"))
        step[f"{node}_temp_max"] = max(fnum(w, "temp_c"))
        step[f"{node}_freq_min_mhz"] = min(fnum(w, "freq_mhz"))
        step[f"{node}_throttled_frac"] = statistics.fmean(thr)
        step[f"{node}_sd_write_kbs"] = statistics.fmean(fnum(w, "sd_write_kbs"))
        if any(v == 1 for v in uv):
            step["valid"] = False
            step["reasons"].append(f"{node}: undervoltage during the step")
        if statistics.fmean(thr) > THROTTLE_WARN_FRACTION:
            step["warnings"].append(f"{node}: CPU throttled in {100 * statistics.fmean(thr):.0f}% of the samples")

    for node in PI_NODES:
        r = rtt_stats(os.path.join(step_dir, f"rtt-{node}.txt"))
        if r:
            step[f"rtt_{node}_avg_ms"], step[f"rtt_{node}_p95_ms"], step[f"rtt_{node}_max_ms"] = r

    # A frozen host (laptop sleep) or a network blackout delays everything at once: pings answered minutes late,
    # a hole in the sampler timestamps. Such a step says nothing about the system under test.
    for node in PI_NODES:
        if step.get(f"rtt_{node}_max_ms", 0) > STALL_RTT_MS:
            step["valid"] = False
            step["reasons"].append(f"{node}: ICMP round trip of {step[f'rtt_{node}_max_ms'] / 1000:.0f} s (host or network stalled)")
    all_mac = read_csv(os.path.join(step_dir, "samples-mac.csv"))
    mac_ts = sorted(int(r["ts_ms"]) for r in all_mac if str(r.get("ts_ms", "")).isdigit() and t_first - 5000 <= int(r["ts_ms"]) <= t_end + 5000)
    if len(mac_ts) > 1:
        gap = max(b - a for a, b in zip(mac_ts, mac_ts[1:])) / 1000.0
        if gap > STALL_SAMPLER_GAP_S:
            step["valid"] = False
            step["reasons"].append(f"this machine stopped sampling for {gap:.0f} s (sleep?)")

    # Wi-Fi jitter does not invalidate a step but distorts the latency tail (p95/p99), so say so.
    for node in PI_NODES:
        p95, mx = step.get(f"rtt_{node}_p95_ms"), step.get(f"rtt_{node}_max_ms")
        if p95 is not None and (p95 > JITTER_RTT_P95_MS or mx > JITTER_RTT_MAX_MS):
            step["warnings"].append(f"{node}: network jitter (ICMP RTT p95 {p95:.0f} ms, max {mx:.0f} ms): read the latency tail with care")

    mac = window_samples(read_csv(os.path.join(step_dir, "samples-mac.csv")), t_first, t_end, margin_ms=2000)
    if mac:
        busy = [100.0 - v for v in fnum(mac, "cpu_idle_pct")]
        step["mac_cpu_mean"], step["mac_cpu_max"] = statistics.fmean(busy), max(busy)

    uv_path = os.path.join(step_dir, "kernel-uv.json")
    if os.path.exists(uv_path):
        for node, c in json.load(open(uv_path)).items():
            if c.get("after", 0) > c.get("before", 0):
                step["valid"] = False
                step["reasons"].append(f"{node}: {c['after'] - c['before']} undervoltage message(s) in the kernel log")
    return step


def saturation(steps):
    """Per repetition and operation: first saturated step and highest sustainable offered rate."""
    result = {}
    groups = {}
    for s in steps:
        if s.get("status") == "ok":
            groups.setdefault((s["rep"], s["op"]), []).append(s)
    for key, group in groups.items():
        group.sort(key=lambda s: s["tps"])
        base_p95 = next((s["lat_p95"] for s in group if s["valid"] and s["lat_p95"] == s["lat_p95"]), None)
        sustainable, first_sat, why = None, None, ""
        for s in group:
            if not s["valid"]:
                continue
            reasons = list(s.get("saturation_reasons", []))
            if base_p95 and s["lat_p95"] > SATURATION_P95_FACTOR * base_p95 and s["tps"] != group[0]["tps"]:
                reasons.append(f"p95 {s['lat_p95']:.0f} ms > {SATURATION_P95_FACTOR:.0f}x the baseline")
            if reasons:
                first_sat, why = s["tps"], "; ".join(reasons)
                break
            sustainable = s["tps"]
        result[key] = {"sustainable_tps": sustainable, "saturated_at_tps": first_sat, "why": why}
    return result


def aggregate(steps):
    groups = {}
    for s in steps:
        if s.get("status") == "ok" and s["valid"]:
            groups.setdefault((s["op"], s["tps"]), []).append(s)
    rows = []
    for (op, tps), group in sorted(groups.items()):
        row = {"op": op, "offered_tps": tps, "n_reps": len(group)}
        for key in ("send_tps", "throughput", "lat_p50", "lat_p95", "lat_p99", "fail_pct", "pi3_cpu_mean", "pi5_cpu_mean",
                    "pi3_temp_max", "pi5_temp_max", "mac_cpu_mean", "rtt_pi3_p95_ms", "rtt_pi5_p95_ms"):
            m, sd, ci = mean_ci([g.get(key, float("nan")) for g in group])
            row[f"{key}_mean"], row[f"{key}_sd"], row[f"{key}_ci95"] = m, sd, ci
        rows.append(row)
    return rows


def fmt(v, digits=1):
    return "-" if v != v else f"{v:.{digits}f}"


def pm(mean, ci, digits=1):
    if mean != mean:
        return "-"
    return f"{mean:.{digits}f}" if ci != ci else f"{mean:.{digits}f} ± {ci:.{digits}f}"


def write_outputs(exp_dir, steps, sats, agg):
    fields = sorted({k for s in steps for k in s if k not in ("reasons", "warnings", "saturation_reasons")} | {"saturation_reasons"})
    with open(os.path.join(exp_dir, "steps.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for s in steps:
            row = {k: v for k, v in s.items() if k not in ("reasons", "warnings", "saturation_reasons")}
            row["saturation_reasons"] = " | ".join(s.get("saturation_reasons", []))
            row["reasons"] = " | ".join(s["reasons"])
            row["warnings"] = " | ".join(s["warnings"])
            w.writerow({k: row.get(k, "") for k in fields})
    if agg:
        with open(os.path.join(exp_dir, "summary.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(agg[0].keys()))
            w.writeheader()
            w.writerows(agg)

    lines = [f"# Experiment {os.path.basename(exp_dir.rstrip('/'))}", ""]
    env = os.path.join(exp_dir, "environment.md")
    if os.path.exists(env):
        lines += [f"Environment: see `environment.md`.", ""]
    ops = sorted({r["op"] for r in agg} | {s["op"] for s in steps})
    for op in ops:
        lines += [f"## {op}", "",
                  "| Offered TPS | Reps | Sent (TPS) | Throughput (TPS) | p50 (ms) | p95 (ms) | p99 (ms) | Fail % | Pi3 CPU % | Pi5 CPU % | Pi3 °C | Pi5 °C | RTT p95 Pi3/Pi5 (ms) |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in [r for r in agg if r["op"] == op]:
            lines.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} / {} |".format(
                r["offered_tps"], r["n_reps"], pm(r["send_tps_mean"], r["send_tps_ci95"]),
                pm(r["throughput_mean"], r["throughput_ci95"]), pm(r["lat_p50_mean"], r["lat_p50_ci95"], 0),
                pm(r["lat_p95_mean"], r["lat_p95_ci95"], 0), pm(r["lat_p99_mean"], r["lat_p99_ci95"], 0),
                fmt(r["fail_pct_mean"]), fmt(r["pi3_cpu_mean_mean"], 0), fmt(r["pi5_cpu_mean_mean"], 0),
                fmt(r["pi3_temp_max_mean"], 0), fmt(r["pi5_temp_max_mean"], 0),
                fmt(r["rtt_pi3_p95_ms_mean"], 0), fmt(r["rtt_pi5_p95_ms_mean"], 0)))
        lines.append("")
        op_sats = {k: v for k, v in sats.items() if k[1] == op}
        if op_sats:
            lines += ["Saturation per repetition:", ""]
            for (rep, _), v in sorted(op_sats.items()):
                if v["sustainable_tps"] is None and v["saturated_at_tps"] is None:
                    lines.append(f"- {rep}: no valid step")
                elif v["saturated_at_tps"] is None:
                    lines.append(f"- {rep}: not reached (sustained up to {v['sustainable_tps']} TPS)")
                else:
                    lines.append(f"- {rep}: saturated at {v['saturated_at_tps']} TPS ({v['why']}); "
                                 f"sustainable up to {v['sustainable_tps']} TPS")
            lines.append("")

    bad = [s for s in steps if not s["valid"]]
    warned = [s for s in steps if s["valid"] and s["warnings"]]
    lines += ["## Excluded steps", ""]
    lines += [f"- {s['rep']}/{s['op']}-{s['tps']}: {'; '.join(s['reasons'])}" for s in bad] or ["None."]
    lines += ["", "## Warnings (steps kept)", ""]
    lines += [f"- {s['rep']}/{s['op']}-{s['tps']}: {'; '.join(s['warnings'])}" for s in warned] or ["None."]
    lines.append("")
    text = "\n".join(lines)
    with open(os.path.join(exp_dir, "summary.md"), "w") as f:
        f.write(text)
    return text


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("experiment_dir")
    p.add_argument("--trim", type=float, default=2.0, help="seconds ignored at both ends of a round (default 2)")
    p.add_argument("--step", action="store_true", help="analyze a single step directory and print JSON")
    a = p.parse_args()

    if a.step:
        s = analyze_step(a.experiment_dir.rstrip("/"), a.trim)
        json.dump(s, sys.stdout, indent=2, default=str)
        print()
        return

    exp = a.experiment_dir.rstrip("/")
    steps = []
    for meta in sorted(glob.glob(os.path.join(exp, "rep*", "*", "meta.json"))):
        s = analyze_step(os.path.dirname(meta), a.trim)
        if s:
            steps.append(s)
    if not steps:
        sys.exit(f"no steps found under {exp}")
    print(write_outputs(exp, steps, saturation(steps), aggregate(steps)))


if __name__ == "__main__":
    main()
