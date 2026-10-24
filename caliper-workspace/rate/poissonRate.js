'use strict';

// Caliper rate controller with Poisson arrivals: independent clients, exponentially distributed gaps.
//
// Why not "fixed-rate": it starts every worker at the same instant and fires at fixed intervals, so the
// transactions of all workers arrive together in bursts. Against a batching orderer the measured latency
// then depends on the phase between that period and the batch timeout (4 workers at 0.5 TPS each and a 2 s
// batch timeout give 0.2 s for half of the transactions and 2.2 s for the other half). Emergency calls are
// independent events, so a Poisson process is also the more faithful workload model.
//
// opts.tps is the TOTAL rate; each worker draws gaps with mean workers/tps seconds. The next arrival time is
// kept on this controller's own clock: unlike the built-in fixed-rate it does not read the connector's count of
// submitted transactions, so delaying or batching inside the workload cannot make it fire a burst to "catch up".

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class PoissonRate {
    constructor(testMessage, stats, workerIndex) {
        const opts = testMessage.getRateControlSpec().opts || {};
        const tps = opts.tps ? opts.tps : 10;
        const workers = testMessage.getWorkersNumber();
        this.meanGapMs = 1000 / (tps / workers);
        this.next = null;
    }

    async applyRateControl() {
        const now = Date.now();
        if (this.next === null) {
            this.next = now;
        }
        // exponential gap: -ln(U) * mean, with U in (0, 1]
        this.next += -Math.log(1 - Math.random()) * this.meanGapMs;
        const wait = this.next - Date.now();
        if (wait > 0) {
            await sleep(wait);
        }
    }

    async end() { }
}

function createRateController(testMessage, stats, workerIndex) {
    return new PoissonRate(testMessage, stats, workerIndex);
}

module.exports.createRateController = createRateController;
