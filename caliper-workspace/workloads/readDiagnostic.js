'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const { request, seedRecords, pick, newRunId, timedSend } = require('./common');

// Round: ReadDiagnosis as the audit organization, over a pre-populated set of records.
class ReadDiagnosticWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        const records = roundArguments.records || 50;
        const prefix = `read-${newRunId()}-${workerIndex}-${roundIndex}`;
        this.ids = await seedRecords(this.sutAdapter, prefix, records, 0);
    }

    async submitTransaction() {
        await timedSend(this, request('audit', 'ReadDiagnosis', [pick(this.ids)], true));
    }
}

module.exports.createWorkloadModule = () => new ReadDiagnosticWorkload();
