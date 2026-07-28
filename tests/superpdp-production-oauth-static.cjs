const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const oauth=read('supabase/functions/superpdp-oauth/index.ts');
const connector=read('supabase/functions/platform-connector/index.ts');
const migration=read('supabase/migrations/202607280101_superpdp_production_oauth.sql');
const workflow=read('.github/workflows/superpdp-worker.yml');
const config=read('supabase/config.toml');
const docs=read('docs/SUPERPDP_PRODUCTION_SETUP.md');

const checks={
  callback_has_pkce:oauth.includes('code_challenge_method: "S256"')&&oauth.includes('code_verifier: verifier'),
  callback_state_is_hashed_and_one_time:oauth.includes('state_hash: await sha256(state)')&&oauth.includes('.is("consumed_at", null)')&&oauth.includes('oauth_state_already_used'),
  company_binding:oauth.includes('superpdp_company_number_scheme: "fr_siren"')&&oauth.includes('provider_company_mismatch'),
  official_verification_states:oauth.includes('companyVerification === "verified"')&&oauth.includes('user_identity_verification_status'),
  official_directory_shape:oauth.includes('directoryPayload.data')&&oauth.includes('["created", "active", "ok", "enabled"]'),
  tokens_encrypted:oauth.includes('AES-GCM')&&oauth.includes('access_token_ciphertext: await encrypt(accessToken)'),
  tokens_never_browser_readable:migration.includes('revoke all on public.superpdp_company_authorizations')&&migration.includes('superpdp_oauth_states'),
  immutable_consent_log:migration.includes('superpdp_consent_events_immutable')&&migration.includes('protect_immutable_fiscal_row'),
  finalization_is_queued:migration.includes('documents_queue_superpdp_after_finalization')&&migration.includes("'send_document'"),
  automatic_inbox_queue:migration.includes('enqueue_superpdp_recurring_jobs')&&migration.includes("'sync_incoming'"),
  worker_is_secret_protected:connector.includes('SUPERPDP_WORKER_SECRET')&&connector.includes('workerAuthorized(req)'),
  worker_retries:connector.includes('retry_scheduled')&&connector.includes('Math.pow(2')&&connector.includes('dead_letter'),
  scheduled_worker:workflow.includes('*/5 * * * *')&&workflow.includes('x-piloz-worker-secret')&&workflow.includes('superpdp_process_jobs'),
  edge_jwt_modes:config.includes('[functions.superpdp-oauth]')&&config.includes('[functions.platform-connector]'),
  documented_setup:docs.includes('authorization_code')&&docs.includes('SUPERPDP_PRODUCTION_CLIENT_SECRET')&&docs.includes('SUPERPDP_WORKER_SECRET')
};

const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
