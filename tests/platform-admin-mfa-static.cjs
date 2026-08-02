const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const api=fs.readFileSync(path.join(root,'supabase/functions/platform-admin-api/index.ts'),'utf8');

const checks={
 server_only_admin_api:api.includes('if(action==="users.mfa_reset")')&&api.includes('const authAdmin=privileged()'),
 permission_required:api.includes('requirePermission("users.write")'),
 factors_listed:api.includes('auth.admin.mfa.listFactors({userId})'),
 factors_deleted:api.includes('auth.admin.mfa.deleteFactor({userId,id:factor.id})'),
 operation_audited:api.includes('target_action:"user.sessions_revoked"')&&api.includes('mfa_reset_required:true'),
 profile_mfa_reset_available:api.includes('if(action==="profile.mfa_reset")')&&api.includes('userId:context.user_id'),
 profile_mfa_reset_audited:api.includes('target_action:"platform_admin.mfa_reset"')&&api.includes('deleted_factor_count:factors.length'),
 no_service_key_in_response:!api.includes('SUPABASE_SERVICE_ROLE_KEY:')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
