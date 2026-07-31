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

assert.match(source, /action\s*===\s*["']demo_accounts\.create["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.list["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.delete["']/);
assert.match(source, /auth\.admin\.createUser\(\{email:ownerEmail,password,email_confirm:true/);
assert.match(source, /sendDemoCredentialsEmail\(\{to:ownerEmail,firstName,password\}\)/);
assert.match(source, /credentialsSent:true/);
assert.match(source, /admin_tags:\s*\[\s*["']demo["']\s*,\s*["']seeded["']\s*\]/);
assert.match(source, /status:\s*["']trialing["']\s*,\s*trial_days:\s*14/);
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

console.log("demo account provisioning static checks passed");
