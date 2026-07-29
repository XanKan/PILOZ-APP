const fs=require('node:fs');

const api=fs.readFileSync('supabase/functions/platform-admin-api/index.ts','utf8');
const migration=fs.readFileSync('supabase/migrations/202607290103_simplified_company_provisioning.sql','utf8');

const checks={
  owner_identity_required:api.includes('Le prénom et le nom du propriétaire sont obligatoires.'),
  provisional_label_only:api.includes('Entreprise à configurer — ${firstName} ${lastName}'),
  no_legal_name_required:migration.includes("raise exception 'owner_identity_required'")&&!migration.includes("raise exception 'company_name_required'"),
  onboarding_pending:migration.includes('onboarding_completed=false')&&migration.includes('onboarding_completed_at')&&migration.includes("'onboarding_pending',true"),
  legal_identity_not_invented:migration.includes('case when provisioning_pending then null')&&migration.includes("nullif(trim(target_company->>'legal_name'),'')")&&migration.includes("nullif(trim(target_company->>'siret'),'')"),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
