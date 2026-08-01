const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(
  path.join(root, "supabase", "functions", "platform-admin-api", "index.ts"),
  "utf8",
);
const auditMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010127_platform_admin_server_audit.sql"),
  "utf8",
);
const deletionMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010128_demo_account_secure_deletion.sql"),
  "utf8",
);
const completionMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010129_complete_demo_account_onboarding.sql"),
  "utf8",
);
const repairSeedMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010130_repair_demo_seed_data.sql"),
  "utf8",
);
const identityRepairMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010131_repair_demo_account_identity_and_onboarding.sql"),
  "utf8",
);
const authMetadataBackfillMigration = fs.readFileSync(
  path.join(root, "supabase", "migrations", "202608010132_backfill_demo_auth_metadata.sql"),
  "utf8",
);
const licenseSource = fs.readFileSync(
  path.join(root, "supabase", "functions", "license-access", "index.ts"),
  "utf8",
);
const appShell = fs.readFileSync(path.join(root, "index.html"), "utf8");
const phase1Source = fs.readFileSync(
  path.join(root, "assets", "js", "phase1-foundation.js"),
  "utf8",
);
const onboardingSource = fs.readFileSync(
  path.join(root, "assets", "js", "modules", "onboarding", "professional-onboarding.js"),
  "utf8",
);
const siteOfferSource = fs.readFileSync(
  path.join(root, "assets", "js", "modules", "subscription", "site-offer.js"),
  "utf8",
);

assert.match(source, /action\s*===\s*["']demo_accounts\.create["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.list["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.delete["']/);
assert.match(source, /auth\.admin\.createUser\(\{email:ownerEmail,password,email_confirm:true/);
assert.match(source, /sendDemoCredentialsEmail\(\{to:ownerEmail,firstName,password\}\)/);
assert.match(source, /credentialsSent:true/);
assert.match(source, /admin_tags:\s*\[\s*["']demo["']\s*,\s*["']seeded["']\s*\]/);
assert.match(source, /status:\s*["']trialing["']\s*,\s*trial_days:\s*14/);
assert.match(source, /siret:\s*["']12345678900012["']/);
assert.match(source, /quote_prefix:\s*["']DEV-DEMO["']/);
assert.match(source, /user_preferences"\)\.upsert\(\{user_id:createdUserId,company_id:createdCompanyId,onboarding_completed:true\}/);
assert.match(source, /completedSettings/);
assert.match(source, /metadata:\s*\{\s*demo:\s*true\s*\}/);
assert.match(source, /privileged\(\)\.rpc\(["']append_platform_admin_audit_service["']/);
assert.match(source, /target_actor_user_id:\s*context\.user_id/);
assert.doesNotMatch(source, /client\.rpc\(["']append_platform_admin_audit["']/);
assert.doesNotMatch(source, /credentialsSent:true[\s\S]{0,160}password/);
assert.doesNotMatch(source, /console\.(?:log|info|warn|error)\([^\n]*password/i);
assert.match(auditMigration, /create or replace function public\.append_platform_admin_audit_service/i);
assert.match(auditMigration, /from public,anon,authenticated/i);
assert.match(auditMigration, /to service_role/i);
assert.match(auditMigration, /target_actor_user_id/i);
assert.match(deletionMigration, /platform_admin_delete_suspended_demo_company/i);
assert.match(deletionMigration, /service_role_required/i);
assert.match(deletionMigration, /admin_tags[\s\S]*demo/i);
assert.match(deletionMigration, /platform_status\s*<>\s*'suspended'/i);
assert.match(deletionMigration, /to service_role/i);
assert.match(completionMigration, /admin_tags\s*@>\s*array\[['"]demo['"]\]/i);
assert.match(completionMigration, /onboarding_completed\s*=\s*true/i);
assert.match(completionMigration, /onboarding_completed_at\s*=\s*coalesce/i);
assert.match(repairSeedMigration, /Nova Bâtiment/);
assert.match(repairSeedMigration, /DEMO-SRV-001/);
assert.match(repairSeedMigration, /admin_tags\s*@>\s*array\[['"]demo['"]\]/i);
assert.match(identityRepairMigration, /raw_user_meta_data->>'demo_account'/i);
assert.match(identityRepairMigration, /onboarding_step\s*=\s*7/i);
assert.match(identityRepairMigration, /on conflict\(user_id\) do update/i);
assert.match(authMetadataBackfillMigration, /update auth\.users/i);
assert.match(authMetadataBackfillMigration, /company\.admin_tags[\s\S]*demo/i);
assert.match(authMetadataBackfillMigration, /demo_account['"],true/i);
assert.match(licenseSource, /repairDemoCompany/);
assert.match(licenseSource, /demoCompanyIdentity/);
assert.match(licenseSource, /demoAccount\}/);
assert.match(licenseSource, /auth\.admin\.getUserById\(userId\)/);
assert.match(licenseSource, /auth\.admin\.updateUserById\(userId,\{user_metadata:/);
assert.match(licenseSource, /metadata\.demo_account/);
assert.match(licenseSource, /user_preferences"\)\.upsert\(\{user_id:userId,company_id:companyId,onboarding_completed:true\}/);
assert.match(licenseSource, /siret:\s*["']12345678900012["']/);
assert.match(licenseSource, /Nova Bâtiment/);
assert.match(licenseSource, /DEMO-SRV-001/);
assert.match(licenseSource, /metadata:\s*\{\s*demo:\s*true\s*\}/);
assert.match(appShell, /user_metadata:payload\.user_metadata/);
assert.match(appShell, /function authSessionIsDemo/);
assert.match(appShell, /window\.PilozSessionIsDemo=authSessionIsDemo/);
assert.match(appShell, /user_metadata:j\.user\?\.user_metadata\|\|\{\}/);
assert.match(phase1Source, /function phase1IsDemoSession/);
assert.match(phase1Source, /PilozLicenseContext\?\.demoAccount===true/);
assert.match(phase1Source, /!phase1IsDemoSession\(\)/);
assert.match(phase1Source, /\['idle','loading'\]/);
assert.match(onboardingSource, /function demoAccountBypassesOnboarding/);
assert.match(onboardingSource, /piloz:license-context-ready/);
assert.match(siteOfferSource, /publishLicenseContext\('loading'\)/);
assert.match(siteOfferSource, /publishLicenseContext\('ready',result\)/);
assert.match(appShell, /phase1-foundation\.js\?v=20260801\.3/);
assert.match(appShell, /site-offer\.js\?v=20260801\.1/);
assert.match(appShell, /professional-onboarding\.js\?v=20260801\.1/);

console.log("demo account provisioning static checks passed");
