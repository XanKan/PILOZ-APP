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

assert.match(source, /action\s*===\s*["']demo_accounts\.create["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.list["']/);
assert.match(source, /inviteUserByEmail\(ownerEmail/);
assert.match(source, /admin_tags:\s*\[\s*["']demo["']\s*,\s*["']seeded["']\s*\]/);
assert.match(source, /status:\s*["']trialing["']\s*,\s*trial_days:\s*14/);
assert.match(source, /metadata:\s*\{\s*demo:\s*true\s*\}/);
assert.match(source, /privileged\(\)\.rpc\(["']append_platform_admin_audit_service["']/);
assert.match(source, /target_actor_user_id:\s*context\.user_id/);
assert.doesNotMatch(source, /client\.rpc\(["']append_platform_admin_audit["']/);
assert.doesNotMatch(source, /password\s*:/i);
assert.match(auditMigration, /create or replace function public\.append_platform_admin_audit_service/i);
assert.match(auditMigration, /from public,anon,authenticated/i);
assert.match(auditMigration, /to service_role/i);
assert.match(auditMigration, /target_actor_user_id/i);

console.log("demo account provisioning static checks passed");
