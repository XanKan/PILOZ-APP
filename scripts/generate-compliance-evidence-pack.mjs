#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const stamp = new Date().toISOString().replaceAll(":", "-").replace(/\.\d{3}Z$/, "Z");
const output = path.resolve(process.argv.find(value => value.startsWith("--output="))?.slice(9)
  || path.join(root, "artifacts", `compliance-evidence-${stamp}`));
const allowlisted = ["VERSION", "CHANGELOG.md", "CNAME", ".github/workflows", "compliance", "docs", "supabase/migrations", "supabase/tests", "tests"];
const excludedExtensions = new Set([".png", ".jpg", ".jpeg", ".pdf", ".zip", ".db"]);
const secretPatterns = [
  /SUPABASE_SERVICE_ROLE_KEY\s*=\s*\S+/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /(?:api[_-]?key|secret|token)\s*[:=]\s*["'][A-Za-z0-9_-]{24,}["']/i,
];

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

async function listFiles(directory) {
  const found = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...await listFiles(target));
    else found.push(target);
  }
  return found;
}

await mkdir(output, { recursive: true });
for (const relative of allowlisted) {
  const source = path.join(root, relative);
  try {
    const sourceStat = await stat(source);
    if (sourceStat.isFile()) await cp(source, path.join(output, relative));
    else {
      for (const file of await listFiles(source)) {
        if (excludedExtensions.has(path.extname(file).toLowerCase())) continue;
        const target = path.join(output, path.relative(root, file));
        await mkdir(path.dirname(target), { recursive: true });
        await cp(file, target);
      }
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

const release = {
  generated_at: new Date().toISOString(),
  application: "PILOZ-APP",
  git_commit: git("rev-parse", "HEAD"),
  git_branch: git("branch", "--show-current"),
  git_status_clean: git("status", "--porcelain") === "",
  schema_version: (await readdir(path.join(root, "supabase", "migrations"))).sort().at(-1)?.split("_")[0] || null,
  certification_claim: false,
  contains_production_data: false,
  note: "Dossier technique interne à faire valider ; il ne constitue ni certificat ni attestation.",
};
await writeFile(path.join(output, "RELEASE.json"), JSON.stringify(release, null, 2) + "\n", "utf8");

const copiedFiles = (await listFiles(output)).filter(file => path.basename(file) !== "MANIFEST.json");
const manifestFiles = [];
for (const file of copiedFiles.sort()) {
  const bytes = await readFile(file);
  const text = bytes.toString("utf8");
  const match = secretPatterns.find(pattern => pattern.test(text));
  if (match) throw new Error(`Secret potentiel détecté dans ${path.relative(output, file)}`);
  manifestFiles.push({
    path: path.relative(output, file).replaceAll(path.sep, "/"),
    bytes: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
}
const manifest = {
  format: "piloz-compliance-evidence-pack",
  format_version: "1.0",
  generated_at: release.generated_at,
  git_commit: release.git_commit,
  files: manifestFiles,
  signature_status: "not_configured",
  external_validation_required: true,
};
await writeFile(path.join(output, "MANIFEST.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
console.log(JSON.stringify({ ok: true, output, files: manifestFiles.length, git_commit: release.git_commit }));
