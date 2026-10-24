#!/usr/bin/env bash
# Multi-org Fabric network: 3 Raft orderers + 3 peer orgs (Org1 = emergency, Org2 = hospital, Org3 = audit).
#
#   ./network.sh hosts [apply]  print (or write to /etc/hosts) the name -> address mapping for this machine
#   ./network.sh up             generate crypto material, start containers
#   ./network.sh createChannel  create the channel and join all peers
#   ./network.sh deployCC       package, install, approve and commit the chaincode
#   ./network.sh status         show the containers running on every node
#   ./network.sh down           stop containers and remove volumes and generated artifacts
#   ./network.sh restart        down + up
#
# MODE=local        (default) everything on this machine, docker-compose.yaml
# MODE=distributed  one set of containers per node (Raspberry Pis + this machine), docker-compose.nodes.yaml,
#                   addresses and SSH users come from inventory.env
#
# Admin commands (peer, osnadmin, configtxgen) always run from this machine using the Fabric binaries in
# <repo>/bin, and reach every node by its Fabric host name (peer0.org1.example.com, ...). Those names must
# resolve on this machine: run `./network.sh hosts apply` once per mode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
export PATH="$REPO_DIR/bin:$PATH"

MODE="${MODE:-local}"
CHANNEL_NAME="${CHANNEL_NAME:-auditchannel}"
CC_NAME="${CC_NAME:-diagnostic-log}"
CC_VERSION="${CC_VERSION:-1.0}"
CC_SEQUENCE="${CC_SEQUENCE:-1}"
CC_SRC_PATH="$REPO_DIR/chaincode/diagnostic-logs"
# Org3 does not need to endorse writes, but it keeps a full copy of the ledger.
CC_POLICY="AND('Org1MSP.peer','Org2MSP.peer')"

ORGS="$ROOT_DIR/organizations"
ARTIFACTS="$ROOT_DIR/channel-artifacts"
NODES_ENV="$ROOT_DIR/.nodes.env"
ORDERER_CA="$ORGS/ordererOrganizations/example.com/orderers/orderer1.example.com/tls/ca.crt"
IMAGES=(hyperledger/fabric-peer:2.5 hyperledger/fabric-orderer:2.5 hyperledger/fabric-ccenv:2.5 hyperledger/fabric-baseos:2.5)

case "$MODE" in
  local) ;;
  distributed)
    [ -f "$ROOT_DIR/inventory.env" ] || { echo "missing $ROOT_DIR/inventory.env"; exit 1; }
    # shellcheck disable=SC1091
    source "$ROOT_DIR/inventory.env"
    ;;
  *) echo "unknown MODE '$MODE' (use local or distributed)"; exit 1 ;;
esac

# ---------------------------------------------------------------- topology

peer_port() { case "$1" in 1) echo 7051 ;; 2) echo 9051 ;; 3) echo 11051 ;; esac; }
orderer_port() { case "$1" in 1) echo 7050 ;; 2) echo 8050 ;; 3) echo 9050 ;; esac; }
orderer_admin_port() { case "$1" in 1) echo 7053 ;; 2) echo 8053 ;; 3) echo 9053 ;; esac; }
peer_name() { echo "peer0.org$1.example.com"; }
orderer_name() { echo "orderer$1.example.com"; }
peer_addr() { echo "$(peer_name "$1"):$(peer_port "$1")"; }
peer_tls_ca() { echo "$ORGS/peerOrganizations/org$1.example.com/peers/peer0.org$1.example.com/tls/ca.crt"; }

# Node that hosts each component in distributed mode (docker-compose.nodes.yaml profiles).
NODES="pi3 pi5 mac"
node_of_peer() { case "$1" in 1) echo pi3 ;; 2) echo pi5 ;; 3) echo mac ;; esac; }
node_of_orderer() { case "$1" in 1) echo pi5 ;; 2) echo mac ;; 3) echo mac ;; esac; }
node_host() { case "$1" in pi3) echo "$PI3_HOST" ;; pi5) echo "$PI5_HOST" ;; mac) echo "$MAC_HOST" ;; esac; }
node_user() { case "$1" in pi3) echo "$PI3_USER" ;; pi5) echo "$PI5_USER" ;; mac) echo "" ;; esac; }
# Nodes at this machine's address run locally, without SSH.
node_is_local() { [ "$1" = mac ] || [ "$(node_host "$1")" = "$MAC_HOST" ]; }

# Address that the given Fabric host name must resolve to on this machine.
expected_ip() {
  local name="$1" n
  if [ "$MODE" = local ]; then echo 127.0.0.1; return; fi
  case "$name" in
    peer0.org*) n="${name#peer0.org}"; n="${n%%.*}"; node_host "$(node_of_peer "$n")" ;;
    orderer*) n="${name#orderer}"; n="${n%%.*}"; node_host "$(node_of_orderer "$n")" ;;
  esac
}

all_names() {
  local n
  for n in 1 2 3; do orderer_name "$n"; done
  for n in 1 2 3; do peer_name "$n"; done
}

resolve() { python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$1" 2>/dev/null || true; }

hosts_block() {
  local name
  echo "# >>> telehealth-fabric ($MODE)"
  for name in $(all_names); do echo "$(expected_ip "$name") $name"; done
  echo "# <<< telehealth-fabric"
}

hosts_cmd() {
  [ "$MODE" = local ] || check_inventory
  if [ "${1:-}" = apply ]; then
    local tmp
    tmp="$(mktemp)"
    # drop any previous block, then append the current one
    sudo sh -c "sed '/# >>> telehealth-fabric/,/# <<< telehealth-fabric/d' /etc/hosts > '$tmp' && cat '$tmp' > /etc/hosts"
    hosts_block | sudo tee -a /etc/hosts >/dev/null
    rm -f "$tmp"
    echo "/etc/hosts updated for MODE=$MODE"
  else
    hosts_block
    echo
    echo "Run './network.sh hosts apply' (asks for sudo) to write this block to /etc/hosts."
  fi
}

check_hosts() {
  local name want got bad=0
  for name in $(all_names); do
    want="$(expected_ip "$name")"
    got="$(resolve "$name")"
    if [ "$got" != "$want" ]; then
      echo "name $name resolves to '${got:-nothing}', expected $want"
      bad=1
    fi
  done
  if [ "$bad" = 1 ]; then
    echo "Fix with: MODE=$MODE ./network.sh hosts apply"
    exit 1
  fi
}

# ---------------------------------------------------------------- peer CLI

# Point the peer CLI at the admin of org $1.
use_org() {
  local n="$1"
  export FABRIC_CFG_PATH="$REPO_DIR/config"
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="Org${n}MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$(peer_tls_ca "$n")"
  export CORE_PEER_MSPCONFIGPATH="$ORGS/peerOrganizations/org$n.example.com/users/Admin@org$n.example.com/msp"
  export CORE_PEER_ADDRESS="$(peer_addr "$n")"
}

# Orderer used for peer commands: orderer1 locally, orderer2 (on this machine) when distributed.
ORDERER_N=1
[ "$MODE" = distributed ] && ORDERER_N=2
ORDERER_FLAGS=(-o "$(orderer_name "$ORDERER_N"):$(orderer_port "$ORDERER_N")" --ordererTLSHostnameOverride "$(orderer_name "$ORDERER_N")" --tls --cafile "$ORDERER_CA")

check_tools() {
  local t
  for t in cryptogen configtxgen osnadmin peer; do
    command -v "$t" >/dev/null || { echo "missing binary: $t (expected in $REPO_DIR/bin)"; exit 1; }
  done
  docker info >/dev/null 2>&1 || { echo "Docker daemon is not running on this machine"; exit 1; }
}

wait_port() {
  local host="$1" port="$2" i
  for i in $(seq 1 30); do
    if python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 2).close()' "$host" "$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for $host:$port"
  return 1
}

# ---------------------------------------------------------------- nodes (distributed mode)

write_nodes_env() {
  printf 'MAC_HOST=%s\nPI3_HOST=%s\nPI5_HOST=%s\n' "$MAC_HOST" "$PI3_HOST" "$PI5_HOST" > "$NODES_ENV"
}

check_inventory() {
  local v
  for v in MAC_HOST PI3_HOST PI5_HOST PI3_USER PI5_USER; do
    case "${!v:-}" in
      ""|CHANGE_ME) echo "set $v in $ROOT_DIR/inventory.env"; exit 1 ;;
    esac
  done
}

# Run a command on node $1: locally, or over SSH in the remote directory.
node_exec() {
  local node="$1"; shift
  if node_is_local "$node"; then
    (cd "$ROOT_DIR" && bash -c "$*")
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$(node_user "$node")@$(node_host "$node")" "cd $REMOTE_DIR && $*"
  fi
}

# Crypto material that node $1 needs: only its own peers and orderers.
node_crypto_paths() {
  local node="$1" n
  for n in 1 2 3; do
    if [ "$(node_of_peer "$n")" = "$node" ]; then
      echo "organizations/peerOrganizations/org$n.example.com/peers/peer0.org$n.example.com/msp"
      echo "organizations/peerOrganizations/org$n.example.com/peers/peer0.org$n.example.com/tls"
    fi
    if [ "$(node_of_orderer "$n")" = "$node" ]; then
      echo "organizations/ordererOrganizations/example.com/orderers/orderer$n.example.com/msp"
      echo "organizations/ordererOrganizations/example.com/orderers/orderer$n.example.com/tls"
    fi
  done
}

# Fail early, before anything is copied or started, if a remote node is unreachable.
preflight_nodes() {
  local node dest bad=0
  for node in $NODES; do
    node_is_local "$node" && continue
    dest="$(node_user "$node")@$(node_host "$node")"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$dest" true 2>/dev/null; then
      echo "node $node ($dest) is unreachable over SSH"
      bad=1
    fi
  done
  [ "$bad" = 0 ] || { echo "Nothing was changed. Check power and network on the node(s) above, then run again."; exit 1; }
}

provision_node() {
  local node="$1" dest paths
  if node_is_local "$node"; then
    docker compose -f "$ROOT_DIR/docker-compose.nodes.yaml" --env-file "$NODES_ENV" --profile "$node" pull --ignore-pull-failures >/dev/null 2>&1 || true
    return
  fi
  dest="$(node_user "$node")@$(node_host "$node")"
  echo ">> Provisioning $node ($dest)"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$dest" "mkdir -p $REMOTE_DIR" \
    || { echo "cannot reach $dest over SSH: check that the node is powered on and its address is still $(node_host "$node"), and that key login works (ssh-copy-id $dest)"; exit 1; }
  scp -q "$ROOT_DIR/docker-compose.nodes.yaml" "$dest:$REMOTE_DIR/docker-compose.nodes.yaml"
  scp -q "$NODES_ENV" "$dest:$REMOTE_DIR/.env"
  # shellcheck disable=SC2046
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$ROOT_DIR" -cf - $(node_crypto_paths "$node") | ssh "$dest" "tar -C $REMOTE_DIR -xf -"
  ssh "$dest" "docker --version >/dev/null && docker compose version >/dev/null" \
    || { echo "Docker with the compose plugin is missing on $node (see prepare-node.sh)"; exit 1; }
  local img
  for img in "${IMAGES[@]}"; do
    ssh "$dest" "docker image inspect $img >/dev/null 2>&1 || docker pull -q $img" >/dev/null
  done
}

compose_node() {
  local node="$1"; shift
  node_exec "$node" "docker compose -f docker-compose.nodes.yaml --env-file $( node_is_local "$node" && echo "$NODES_ENV" || echo .env ) --profile $node $*"
}

# ---------------------------------------------------------------- commands

# New crypto material cannot be used with ledgers created from older material. Refuse to start in that case.
check_no_stale_volumes() {
  local node found
  if [ "$MODE" = local ]; then
    found="$(docker volume ls -q | grep -E 'example\.com$' || true)"
    [ -z "$found" ] || { echo "stale Docker volumes from a previous network:"; echo "$found"; echo "Run './network.sh down' first."; exit 1; }
    return
  fi
  check_inventory
  for node in $NODES; do
    found="$(node_exec "$node" "docker volume ls -q | grep -E 'example\.com\$' || true" 2>/dev/null || true)"
    [ -z "$found" ] || { echo "stale Docker volumes on $node:"; echo "$found"; echo "Run 'MODE=$MODE ./network.sh down' first."; exit 1; }
  done
}

network_up() {
  check_tools
  if [ ! -d "$ORGS/peerOrganizations" ]; then
    check_no_stale_volumes
    echo ">> Generating crypto material"
    rm -rf "$ORGS"
    cryptogen generate --config="$ROOT_DIR/crypto-config.yaml" --output="$ORGS"
  fi

  if [ "$MODE" = local ]; then
    echo ">> Starting containers"
    docker compose -f "$ROOT_DIR/docker-compose.yaml" up -d
    docker compose -f "$ROOT_DIR/docker-compose.yaml" ps
    return
  fi

  check_inventory
  write_nodes_env
  local node
  preflight_nodes
  for node in $NODES; do provision_node "$node"; done
  for node in $NODES; do
    echo ">> Starting containers on $node"
    compose_node "$node" up -d
  done
  network_status
}

network_status() {
  if [ "$MODE" = local ]; then
    docker compose -f "$ROOT_DIR/docker-compose.yaml" ps
    return
  fi
  local node
  for node in $NODES; do
    echo "== $node ($(node_host "$node"))"
    compose_node "$node" ps || echo "   unreachable"
  done
}

network_down() {
  echo ">> Stopping containers and removing volumes"
  if [ "$MODE" = local ]; then
    docker compose -f "$ROOT_DIR/docker-compose.yaml" down -v --remove-orphans || true
    docker ps -aq --filter "name=dev-peer" | xargs -r docker rm -f 2>/dev/null || true
    docker images -q "dev-peer*" | xargs -r docker rmi -f 2>/dev/null || true
  else
    check_inventory
    write_nodes_env
    local node
    for node in $NODES; do
      echo ">> $node"
      compose_node "$node" down -v --remove-orphans || echo "   could not reach $node"
      node_exec "$node" 'docker ps -aq --filter "name=dev-peer" | xargs -r docker rm -f; docker images -q "dev-peer*" | xargs -r docker rmi -f' 2>/dev/null || true
      node_is_local "$node" || node_exec "$node" "rm -rf organizations" 2>/dev/null || true
    done
  fi
  rm -rf "$ORGS" "$ARTIFACTS"
}

create_channel() {
  check_tools
  check_hosts
  mkdir -p "$ARTIFACTS"

  local n
  for n in 1 2 3; do wait_port "$(orderer_name "$n")" "$(orderer_admin_port "$n")"; done
  for n in 1 2 3; do wait_port "$(peer_name "$n")" "$(peer_port "$n")"; done

  echo ">> Generating channel genesis block for '$CHANNEL_NAME'"
  FABRIC_CFG_PATH="$ROOT_DIR" configtxgen \
    -profile ThreeOrgsApplicationGenesis \
    -outputBlock "$ARTIFACTS/$CHANNEL_NAME.block" \
    -channelID "$CHANNEL_NAME"

  local tls="$ORGS/ordererOrganizations/example.com/orderers"
  for n in 1 2 3; do
    echo ">> Joining orderer$n to the channel"
    osnadmin channel join \
      --channelID "$CHANNEL_NAME" \
      --config-block "$ARTIFACTS/$CHANNEL_NAME.block" \
      -o "$(orderer_name "$n"):$(orderer_admin_port "$n")" \
      --ca-file "$ORDERER_CA" \
      --client-cert "$tls/orderer$n.example.com/tls/server.crt" \
      --client-key "$tls/orderer$n.example.com/tls/server.key"
  done

  # let the Raft cluster elect a leader before the peers connect
  sleep 5

  for n in 1 2 3; do
    echo ">> Joining $(peer_name "$n") to the channel"
    use_org "$n"
    local attempt
    for attempt in 1 2 3 4 5; do
      peer channel join -b "$ARTIFACTS/$CHANNEL_NAME.block" && break
      echo "   join failed (attempt $attempt), retrying..."
      sleep 3
    done
  done
  echo ">> Channel '$CHANNEL_NAME' ready (anchor peers come from configtx.yaml)"
}

deploy_cc() {
  check_tools
  check_hosts
  local pkg="$ARTIFACTS/$CC_NAME.tar.gz"
  mkdir -p "$ARTIFACTS"

  echo ">> Vendoring chaincode dependencies"
  (cd "$CC_SRC_PATH" && go mod tidy && go mod vendor)

  echo ">> Packaging chaincode"
  use_org 1
  peer lifecycle chaincode package "$pkg" \
    --path "$CC_SRC_PATH" --lang golang --label "${CC_NAME}_${CC_VERSION}"
  local pkg_id
  pkg_id="$(peer lifecycle chaincode calculatepackageid "$pkg")"
  echo "   package id: $pkg_id"

  local n
  for n in 1 2 3; do
    use_org "$n"
    # a previous run may have installed it even if the client timed out, and a second install fails
    if peer lifecycle chaincode queryinstalled 2>/dev/null | grep -q "$pkg_id"; then
      echo ">> Chaincode already installed on $(peer_name "$n"), skipping"
      continue
    fi
    echo ">> Installing on $(peer_name "$n") (the peer builds the chaincode image; this is slow on a Raspberry Pi)"
    if ! peer lifecycle chaincode install "$pkg"; then
      # The call can fail (connection reset, client timeout) while the peer is still building and ends up
      # installing the package anyway. Wait for it before giving up.
      echo ">> install returned an error; waiting for $(peer_name "$n") to finish building (up to 15 min)"
      local i
      for i in $(seq 1 90); do
        sleep 10
        peer lifecycle chaincode queryinstalled 2>/dev/null | grep -q "$pkg_id" && break
      done
      peer lifecycle chaincode queryinstalled 2>/dev/null | grep -q "$pkg_id" \
        || { echo "chaincode was not installed on $(peer_name "$n")"; exit 1; }
      echo ">> Chaincode installed on $(peer_name "$n")"
    fi
  done

  for n in 1 2 3; do
    echo ">> Org$n approving the definition"
    use_org "$n"
    peer lifecycle chaincode approveformyorg "${ORDERER_FLAGS[@]}" \
      --channelID "$CHANNEL_NAME" --name "$CC_NAME" --version "$CC_VERSION" \
      --package-id "$pkg_id" --sequence "$CC_SEQUENCE" \
      --signature-policy "$CC_POLICY"
  done

  echo ">> Checking commit readiness"
  use_org 1
  peer lifecycle chaincode checkcommitreadiness \
    --channelID "$CHANNEL_NAME" --name "$CC_NAME" --version "$CC_VERSION" \
    --sequence "$CC_SEQUENCE" --signature-policy "$CC_POLICY" --output json

  echo ">> Committing the definition"
  peer lifecycle chaincode commit "${ORDERER_FLAGS[@]}" \
    --channelID "$CHANNEL_NAME" --name "$CC_NAME" --version "$CC_VERSION" \
    --sequence "$CC_SEQUENCE" --signature-policy "$CC_POLICY" \
    --peerAddresses "$(peer_addr 1)" --tlsRootCertFiles "$(peer_tls_ca 1)" \
    --peerAddresses "$(peer_addr 2)" --tlsRootCertFiles "$(peer_tls_ca 2)" \
    --peerAddresses "$(peer_addr 3)" --tlsRootCertFiles "$(peer_tls_ca 3)"

  sleep 3
  peer lifecycle chaincode querycommitted --channelID "$CHANNEL_NAME" --name "$CC_NAME"
}

case "${1:-}" in
  hosts) hosts_cmd "${2:-}" ;;
  up) network_up ;;
  createChannel) create_channel ;;
  deployCC) deploy_cc ;;
  status) network_status ;;
  down) network_down ;;
  restart) network_down; network_up ;;
  *)
    echo "usage: [MODE=local|distributed] $0 {hosts [apply]|up|createChannel|deployCC|status|down|restart}"
    exit 1
    ;;
esac
