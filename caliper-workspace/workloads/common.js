'use strict';

const fs = require('fs');
const path = require('path');

// Roles map to the identities declared in networkConfig.yaml and to the chaincode ACL:
// emergency (Org1) inserts, hospital (Org2) updates, audit (Org3) reads.
const IDENTITIES = {
    emergency: { invokerMspId: 'Org1MSP', invokerIdentity: 'emergency' },
    hospital: { invokerMspId: 'Org2MSP', invokerIdentity: 'hospital' },
    audit: { invokerMspId: 'Org3MSP', invokerIdentity: 'audit' }
};

const CONTRACT_ID = 'diagnostic-log';
const SEVERITIES = ['red', 'orange', 'yellow', 'green', 'blue'];
const ATTENDANCE_TYPES = ['trauma', 'stroke', 'ami', 'respiratory', 'other'];

function pick(list) {
    return list[Math.floor(Math.random() * list.length)];
}

// Ledger state survives between runs, so every run gets its own ID prefix.
function newRunId() {
    return Date.now().toString(36);
}

function insertArgs(id) {
    return [
        id,
        `patient-${id}`,
        `physician-${Math.floor(Math.random() * 20)}`,
        'synthetic diagnosis',
        'synthetic observation',
        pick(SEVERITIES),
        pick(ATTENDANCE_TYPES),
        `${(-23 - Math.random()).toFixed(5)},${(-46 - Math.random()).toFixed(5)}`,
        // fake SHA-256 hex digest of an off-chain attachment
        Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join('')
    ];
}

function updateArgs(id, newStatus) {
    return [id, newStatus, `reviewed diagnosis for ${id}`, `hospital note for ${id}`, '', '', '', ''];
}

function request(role, contractFunction, contractArguments, readOnly) {
    return Object.assign({
        contractId: CONTRACT_ID,
        contractFunction,
        contractArguments,
        readOnly: Boolean(readOnly)
    }, IDENTITIES[role]);
}

// Sends a request outside the measured rounds and fails loudly if it did not succeed.
async function sendChecked(adapter, req) {
    const result = await adapter.sendRequests(req);
    const results = Array.isArray(result) ? result : [result];
    for (const r of results) {
        if (r.GetStatus && r.GetStatus() !== 'success') {
            throw new Error(`setup transaction ${req.contractFunction}(${req.contractArguments[0]}) failed: ${r.GetStatus()}`);
        }
    }
}

// Inserts `count` records as emergency; when `steps` > 0 the hospital then moves each one
// through OPEN -> UNDER_REVIEW (steps = 1) and CLOSED (steps = 2).
// Records are seeded concurrently: one at a time would wait for a block (BatchTimeout) per transaction.
const SEED_CONCURRENCY = 8;

// A submit returns once the block is committed on the gateway peer of the submitting organization. The other
// endorser may not have applied that block yet and still sees the old state, so a chained update right after
// can be rejected ("invalid status transition: OPEN -> CLOSED"). Setup retries with a growing pause.
async function sendCheckedRetry(adapter, req, attempts = 8) {
    for (let i = 1; ; i++) {
        try {
            return await sendChecked(adapter, req);
        } catch (err) {
            if (i >= attempts) {
                throw err;
            }
            await sleep(400 * i);
        }
    }
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function seedRecords(adapter, prefix, count, steps, concurrency = SEED_CONCURRENCY) {
    const ids = Array.from({ length: count }, (_, i) => `${prefix}-${i}`);
    let next = 0;
    async function lane() {
        while (next < ids.length) {
            const id = ids[next++];
            await sendChecked(adapter, request('emergency', 'InsertDiagnostic', insertArgs(id)));
            if (steps >= 1) {
                await sendCheckedRetry(adapter, request('hospital', 'UpdateDiagnostic', updateArgs(id, 'UNDER_REVIEW')));
            }
            if (steps >= 2) {
                await sendCheckedRetry(adapter, request('hospital', 'UpdateDiagnostic', updateArgs(id, 'CLOSED')));
            }
        }
    }
    await Promise.all(Array.from({ length: Math.min(concurrency, count) }, lane));
    return ids;
}

// Measured send. Besides forwarding to the Caliper adapter it appends one line per transaction to
// $BENCH_RESULTS_DIR/latencies-w<worker>.csv (round, worker, function, start epoch ms, latency ms, ok),
// so percentiles can be computed afterwards: Caliper itself only reports min/avg/max.
// `ctx` is the workload module (`this`). Without BENCH_RESULTS_DIR it is a plain send.
const headerWritten = new Set();

async function timedSend(ctx, req) {
    const dir = process.env.BENCH_RESULTS_DIR;
    const t0 = Date.now();
    let ok = false;
    try {
        const result = await ctx.sutAdapter.sendRequests(req);
        const first = Array.isArray(result) ? result[0] : result;
        ok = !first || !first.GetStatus || first.GetStatus() === 'success';
        return result;
    } finally {
        if (dir) {
            const file = path.join(dir, `latencies-w${ctx.workerIndex}.csv`);
            if (!headerWritten.has(file)) {
                if (!fs.existsSync(file)) {
                    fs.appendFileSync(file, 'round,worker,function,start_ms,latency_ms,ok\n');
                }
                headerWritten.add(file);
            }
            fs.appendFileSync(file, `${ctx.roundIndex},${ctx.workerIndex},${req.contractFunction},${t0},${Date.now() - t0},${ok ? 1 : 0}\n`);
        }
    }
}

module.exports = { request, insertArgs, updateArgs, seedRecords, sendChecked, timedSend, pick, newRunId };
