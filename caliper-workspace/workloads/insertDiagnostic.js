'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const { request, insertArgs, newRunId, timedSend } = require('./common');

// Round: InsertDiagnostic as the emergency organization.
class InsertDiagnosticWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.runId = newRunId();
        this.txIndex = 0;
    }

    async submitTransaction() {
        const id = `diag-${this.runId}-${this.workerIndex}-${this.roundIndex}-${this.txIndex++}`;
        await timedSend(this, request('emergency', 'InsertDiagnostic', insertArgs(id)));
    }
}

module.exports.createWorkloadModule = () => new InsertDiagnosticWorkload();
