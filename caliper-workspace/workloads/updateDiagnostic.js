'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const { request, updateArgs, seedRecords, newRunId, timedSend } = require('./common');

// Round: UpdateDiagnostic as the hospital organization.
//
// The chaincode enforces OPEN -> UNDER_REVIEW -> CLOSED, so a record accepts exactly two updates.
// Each worker therefore seeds `records` OPEN records and sends 2 * records updates: the first pass
// moves every record to UNDER_REVIEW, the second pass closes it. `records` must be at least
// (transactions per worker) / 2, e.g. txNumber 300 over 5 workers -> 60 per worker -> records: 30.
// Passes are `records` transactions apart, so no two in-flight updates touch the same record.
class UpdateDiagnosticWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.records = roundArguments.records;
        if (!this.records) {
            throw new Error('updateDiagnostic requires the "records" round argument');
        }
        const prefix = `upd-${newRunId()}-${workerIndex}-${roundIndex}`;
        this.ids = await seedRecords(this.sutAdapter, prefix, this.records, 0);
        this.txIndex = 0;
    }

    async submitTransaction() {
        if (this.txIndex >= 2 * this.records) {
            throw new Error(`update pool exhausted after ${this.txIndex} transactions: increase "records"`);
        }
        const id = this.ids[this.txIndex % this.records];
        const newStatus = this.txIndex < this.records ? 'UNDER_REVIEW' : 'CLOSED';
        this.txIndex++;
        await timedSend(this, request('hospital', 'UpdateDiagnostic', updateArgs(id, newStatus)));
    }
}

module.exports.createWorkloadModule = () => new UpdateDiagnosticWorkload();
