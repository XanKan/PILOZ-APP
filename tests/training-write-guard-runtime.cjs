const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

let networkCalls = 0;
const context = {
  console,
  fetch: async () => {
    networkCalls += 1;
    throw new Error('Une ecriture de formation ne doit jamais atteindre le reseau.');
  },
  localStorage: { setItem() {} },
  PilozHelp: { isTrainingActive: () => true },
  PilozRuntime: {
    config: { url: 'https://example.supabase.co', key: 'anon' },
    session: { access_token: 'training-token' },
    request: async () => {
      networkCalls += 1;
      throw new Error('Une ecriture de formation ne doit jamais atteindre Supabase.');
    }
  },
  PilozTabSync: { notifyMutation() {} }
};
context.window = context;
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../assets/js/api/erp-api.js'), 'utf8'), context);

async function blocked(operation) {
  await assert.rejects(operation, error => error?.code === 'training_write_blocked');
}

(async () => {
  await blocked(() => context.PilozERP.rpc('save_crm_opportunity_v2', {}));
  await blocked(() => context.PilozERP.rpc('get_or_create_training_opportunity', {}));
  await blocked(() => context.PilozERP.insert('opportunities', {}));
  await blocked(() => context.PilozERP.update('opportunities', 'opportunity-id', {}));
  await blocked(() => context.PilozERP.remove('opportunities', 'opportunity-id'));
  await blocked(() => context.PilozERP.invoke('platform-connector', {}));
  await blocked(() => context.PilozERP.invokeBlob('document-pdf', {}));
  await blocked(() => context.PilozERP.upload('documents', 'test.pdf', { type: 'application/pdf' }));
  assert.equal(networkCalls, 0, 'Aucun appel reseau ne doit partir pendant ces ecritures de formation.');
  console.log(JSON.stringify({ ok: true, blockedWrites: 8, networkCalls }));
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
