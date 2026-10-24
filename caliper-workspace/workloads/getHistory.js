'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const { request, seedRecords, pick, newRunId, timedSend } = require('./common');

// Round: GetHistory as the audit organization. Every record is seeded with its full lifecycle
// (insert + UNDER_REVIEW + CLOSED = 3 history entries), the most a record can have.
class GetHistoryWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        const records = roundArguments.records || 20;
        const prefix = `hist-${newRunId()}-${workerIndex}-${roundIndex}`;
        this.ids = await seedRecords(this.sutAdapter, prefix, records, 2);
    }

    async submitTransaction() {
        await timedSend(this, request('audit', 'GetHistory', [pick(this.ids)], true));
    }
}

module.exports.createWorkloadModule = () => new GetHistoryWorkload();
