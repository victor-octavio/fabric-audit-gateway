# fabric-audit-gateway

A Hyperledger Fabric-based prototype for auditability of diagnostic records in emergency telemedicine scenarios.

## Overview

In emergency telemedicine, diagnostic records pass through multiple organizations — emergency medical services, hospitals, and regulatory auditors. Traditional centralized systems rely on trust in a single operator, making it difficult to guarantee that records haven't been altered after the fact.

This prototype uses Hyperledger Fabric to ensure that every diagnostic record is cryptographically signed, immutably stored, and fully traceable across all participating organizations.

### Organizations

| Name (`X-Org`) | MSP | Role |
|---|---|---|
| `emergency` | `Org1MSP` | Pre-hospital care. Creates diagnostic records in the field. |
| `hospital` | `Org2MSP` | Receives the patient. Updates records and moves them through the status lifecycle. |
| `audit` | `Org3MSP` | Regulation and auditing. Read-only access to records and their full history. |

- **Endorsement policy for writes:** `AND('Org1MSP.peer', 'Org2MSP.peer')`. The audit peer keeps a full copy of the ledger but does not need to endorse.
- **Access control:** enforced in the chaincode from the caller's MSP ID. Only `Org1MSP` can insert, only `Org2MSP` can update, any organization can read.
- **Status lifecycle:** `OPEN → UNDER_REVIEW → CLOSED`. Any other transition is rejected by the chaincode.
- **Ordering:** 3 Raft orderers, TLS between all components, channel created through the channel participation API (no system channel).
- Records never store files. `attachment_hash` holds only the SHA-256 of an attachment kept outside the system.

## Project Structure

```
fabric-telehealth-audit/
├── network/
│   ├── friendly-microfab-setup.sh   # dev mode: single-org Microfab
│   ├── deploy-chaincode.sh
│   └── multi-org/                   # full network: 3 orgs, 3 Raft orderers, TLS
├── chaincode/diagnostic-logs/       # smart contract (Go)
├── gateway/                         # REST API (Go + Gin + Fabric Gateway SDK)
└── caliper-workspace/               # Hyperledger Caliper benchmarks
```

## Architecture
![](./assets/architecture.png)

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (running)
- [Go](https://go.dev/dl/) 1.25+ (gateway), 1.23+ (chaincode)
- [jq](https://jqlang.github.io/jq/download/)
- Fabric 2.5 binaries (`peer`, `configtxgen`, `cryptogen`, `osnadmin`) in `./bin`
- [Node.js](https://nodejs.org/) 18.19+ (only for the Caliper benchmarks)

## Quick Start (Development — Microfab)

```bash
./network/friendly-microfab-setup.sh
source network/fabric-env.sh
chmod +x network/deploy-chaincode.sh
./network/deploy-chaincode.sh
cd gateway && go run cmd/api/main.go
```

Microfab has a single organization, so the chaincode access rules cannot be fully exercised in this mode (a record can be inserted by `Org1MSP` but never updated by `Org2MSP`). Use the full network to test the whole flow.

## Full Network (Multi-Org — 3 organizations)

```bash
./network/multi-org/network.sh hosts apply    # once: maps peer0.org1.example.com, ... to 127.0.0.1 (asks for sudo)
./network/multi-org/network.sh up             # crypto material + containers
./network/multi-org/network.sh createChannel  # channel "auditchannel", joins all peers
./network/multi-org/network.sh deployCC       # install, approve and commit the chaincode
./network/multi-org/network.sh down           # remove containers, volumes and generated files
```

The scripts, the gateway and Caliper reach every node by its Fabric host name, so those names must resolve on this machine.

### Distributed (Raspberry Pi) mode

Runs the nodes on separate machines. This machine keeps the audit peer, two orderers, Caliper and the gateway.

| Node | Runs |
|---|---|
| `pi3` (Raspberry Pi 3 B) | `peer0.org1` (emergency) |
| `pi5` (Raspberry Pi 5) | `peer0.org2` (hospital), `orderer1` |
| `mac` (this machine) | `peer0.org3` (audit), `orderer2`, `orderer3`, Caliper |

1. Install a 64-bit Ubuntu Server on each Pi, give them fixed addresses (router DHCP reservation), prefer Ethernet over Wi-Fi, and set up SSH keys (`ssh-copy-id`).
2. Fill in `network/multi-org/inventory.env` (addresses and SSH users).
3. On each Pi run `network/multi-org/prepare-node.sh` (Docker, swap for the Pi 3, NTP, CPU governor).
4. Then, from this machine:

```bash
export MODE=distributed
./network/multi-org/network.sh hosts apply    # maps the host names to the real addresses
./network/multi-org/network.sh up             # copies each node's crypto material and starts its containers
./network/multi-org/network.sh createChannel
./network/multi-org/network.sh deployCC       # the Pis compile the chaincode image: slow, needs swap on the Pi 3
./network/multi-org/network.sh status
```

Setting every address in `inventory.env` to this machine's address runs the same layout on one machine, which is a quick way to test the scripts before touching the Pis. Switching between `local` and `distributed` needs `down`, then `hosts apply` for the new mode.

Then start the gateway pointing at the three organizations:

```bash
cd gateway
ORGS_CONFIG_PATH=pkg/fabric/orgs.yaml go run cmd/api/main.go
```

Without `ORGS_CONFIG_PATH` the gateway connects as a single organization configured through environment variables (`PEER_ENDPOINT`, `MSP_ID`, `CERT_PATH`, `KEY_PATH`, `TLS_CERT_PATH`, ...), which is what the Microfab mode uses.

## API Endpoints

Every request needs the header `X-Org` (or the query parameter `?org=`) with `emergency`, `hospital` or `audit`. It selects which organization's Fabric identity signs the transaction. **It is not authentication**: anyone who can reach the API can pick any organization. A real deployment must put proper authentication in front of it.

| Method | Route | Organization | Description |
|---|---|---|---|
| `POST` | `/diagnosis/insert` | `emergency` | Create a record (status `OPEN`) |
| `GET` | `/diagnosis/record/:id` | any | Get a record |
| `PUT` | `/diagnosis/update/:id` | `hospital` | Move the record to `new_status` and update its fields |
| `GET` | `/diagnosis/history/:id` | any | Full audit trail: every change with transaction ID and timestamp |

`POST /diagnosis/insert` body:

```json
{
  "id": "diag-001",
  "patient_id": "pat-001",
  "physician_id": "doc-001",
  "diagnosis": "Suspected acute myocardial infarction",
  "observation": "Severe chest pain, sweating and dyspnea",
  "severity": "red",
  "attendance_type": "ami",
  "location": "-23.55052,-46.63331",
  "attachment_hash": "<sha-256 hex>"
}
```

- `severity`: Manchester color — `red`, `orange`, `yellow`, `green`, `blue`.
- `attendance_type`: `trauma`, `stroke`, `ami`, `respiratory`, `other`.

`PUT /diagnosis/update/:id` body: `new_status` is required (`UNDER_REVIEW` or `CLOSED`); every other field is optional and keeps its stored value when omitted.

Error responses: `400` invalid input or unknown organization, `403` the organization may not perform the operation, `404` record not found, `409` invalid status transition or duplicate id.

A ready-to-use Postman collection is in `telehealth-audit.postman_collection.json`.

## Running Benchmarks

The benchmarks use [Hyperledger Caliper](https://hyperledger.github.io/caliper/) 0.6.0 against the multi-org network, so it must be up with the chaincode deployed.

```bash
cd caliper-workspace
./run-benchmark.sh
```

The script installs dependencies on first use and runs two benchmark files:

| File | Workers | Rounds |
|---|---|---|
| `benchmarkConfig.yaml` | 5 | Insert (50 TPS), Read (100 TPS), Update (50 TPS), GetHistory (30 TPS) |
| `benchmarkScalability.yaml` | 10 | Insert at 100 and 200 TPS, mixed workload (60% insert, 20% read, 10% update, 10% history) at 100 TPS |

Reports: `report-baseline.html` and `report-scalability.html`.

For a quick sanity check (about 2 minutes) run `benchmarkSmoke.yaml` with the same `caliper launch manager` flags used in `run-benchmark.sh`.

The update workloads walk each record through `OPEN → UNDER_REVIEW → CLOSED`, so a record accepts at most two updates. Each worker seeds its own pool of records; see the comments in `caliper-workspace/workloads/` before changing `txNumber` or the number of workers.

## Load experiments on the Raspberry Pi testbed

`caliper-workspace/experiment/` runs repeatable experiments with the monitoring and statistics needed to defend the
numbers. The network must be up (`MODE=distributed ./network/multi-org/network.sh ...`) and `hosts apply` done.

```bash
cd caliper-workspace
./experiment/run-experiment.sh --ops "insert read" --tps "2 5 10 20 40 60" --duration 30 --reps 3 --name pilot
```

For each repetition, operation and offered rate (a *step*) the driver:

1. runs a short **warm-up** round, then the measured round at a fixed rate for a fixed time;
2. samples, once per second, CPU, memory, swap, SD-card I/O, temperature, clock frequency and the undervoltage
   alarm on both Pis (plus CPU on this machine), and logs the ICMP round trip to each Pi, during the step;
3. records the latency of **every transaction** (the workloads write it), so p50/p95/p99 can be computed;
4. waits for the Pis to **cool down** before the next step, and stops climbing the rate ladder once the system saturates.

`analyze.py` then produces `results/<name>/summary.md`, `summary.csv` and `steps.csv`:

- throughput and latency percentiles per offered rate, mean and 95% confidence interval across repetitions;
- the load on each node (CPU, temperature) and the RTT p95 next to each result;
- **excluded steps**: any step with an undervoltage alarm, or undervoltage messages in the kernel log, is invalid;
- **saturation** per repetition: failures above 1%, latency growing inside the round (queueing), p95 above 3x the
  baseline, or Caliper-style throughput below 80% of the offered rate;
- `environment.md`: hardware, OS, storage, network link and latency of every node, for the methodology section.

Notes for interpreting the results:

- With little load a write waits for the block to be cut: latency is roughly uniform between 0 and the orderer
  `BatchTimeout` (2 s), so p50 is about 1 s. It drops as blocks fill, which is why latency can fall as load rises.
- Throughput is Caliper's definition (successes / time until the last completion), so it reads a few percent below
  the offered rate on short rounds. Use rounds of 30 s or more.
- `analyze.py <results-dir>` can be re-run at any time; `--trim <s>` changes the seconds ignored at both ends.
- The raw `results/` directory is git-ignored.

## Technology Stack

- **Hyperledger Fabric 2.5** — permissioned blockchain platform (Raft ordering, TLS)
- **Hyperledger Caliper** — performance benchmarking
- **Microfab** — lightweight Fabric network for local development
- **Go** — chaincode and API
- **Gin** — HTTP router
- **Fabric Gateway SDK** — gRPC-based client for Fabric

## License

This project is part of an academic thesis and is provided as-is for educational purposes.
