#!/usr/bin/env bash
# Runs the baseline and scalability benchmarks against the multi-org network
# (network.sh up && createChannel && deployCC must have been run first).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -d node_modules ] || { npm install && npx caliper bind --caliper-bind-sut fabric:fabric-gateway; }

run() {
  npx caliper launch manager \
    --caliper-workspace ./ \
    --caliper-networkconfig networkConfig.yaml \
    --caliper-benchconfig "$1" \
    --caliper-flow-only-test \
    --caliper-fabric-gateway-enabled \
    --caliper-report-path "$2"
}

run benchmarkConfig.yaml report-baseline.html
run benchmarkScalability.yaml report-scalability.html
echo "Reports: report-baseline.html report-scalability.html"
