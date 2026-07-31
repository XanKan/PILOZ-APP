const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(
  path.join(root, "supabase", "functions", "platform-admin-api", "index.ts"),
  "utf8",
);

assert.match(source, /action\s*===\s*["']demo_accounts\.create["']/);
assert.match(source, /action\s*===\s*["']demo_accounts\.list["']/);
assert.match(source, /inviteUserByEmail\(ownerEmail/);
assert.match(source, /admin_tags:\s*\[\s*["']demo["']\s*,\s*["']seeded["']\s*\]/);
assert.match(source, /status:\s*["']trialing["']\s*,\s*trial_days:\s*14/);
assert.match(source, /metadata:\s*\{\s*demo:\s*true\s*\}/);
assert.doesNotMatch(source, /password\s*:/i);

console.log("demo account provisioning static checks passed");
