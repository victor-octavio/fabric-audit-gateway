'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const { request, insertArgs, updateArgs, seedRecords, pick, newRunId, timedSend } = require('./common');

// Round: emergency-care traffic mix. Transaction i of each worker is chosen by i % 10:
//   0-5 -> InsertDiagnostic (60%)   6-7 -> ReadDiagnosis (20%)
//   8   -> UpdateDiagnostic (10%)   9   -> GetHistory (10%)
// Updates walk a pool of OPEN records twice (UNDER_REVIEW, then CLOSED), see updateDiagnostic.js.
// `updateRecords` must be at least (transactions per worker) / 10 / 2.
class MixedWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        const runId = newRunId();
        this.prefix = `mix-${runId}-${workerIndex}-${roundIndex}`;
        this.updateRecords = roundArguments.updateRecords || 10;
        this.readIds = await seedRecords(this.sutAdapter, `${this.prefix}-r`, roundArguments.readRecords || 20, 2);
        this.updateIds = await seedRecords(this.sutAdapter, `${this.prefix}-u`, this.updateRecords, 0);
        this.txIndex = 0;
        this.insertCount = 0;
        this.updateCount = 0;
    }

    async submitTransaction() {
        const slot = this.txIndex++ % 10;
        if (slot <= 5) {
            const id = `${this.prefix}-i-${this.insertCount++}`;
            return timedSend(this, request('emergency', 'InsertDiagnostic', insertArgs(id)));
        }
        if (slot <= 7) {
            return timedSend(this, request('audit', 'ReadDiagnosis', [pick(this.readIds)], true));
        }
        if (slot === 8) {
            const n = this.updateCount++;
            if (n >= 2 * this.updateRecords) {
                throw new Error(`update pool exhausted after ${n} updates: increase "updateRecords"`);
            }
            const id = this.updateIds[n % this.updateRecords];
            const newStatus = n < this.updateRecords ? 'UNDER_REVIEW' : 'CLOSED';
            return timedSend(this, request('hospital', 'UpdateDiagnostic', updateArgs(id, newStatus)));
        }
        return timedSend(this, request('audit', 'GetHistory', [pick(this.readIds)], true));
    }
}

module.exports.createWorkloadModule = () => new MixedWorkload();
