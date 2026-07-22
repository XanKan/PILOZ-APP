#!/usr/bin/env node
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const version = (await readFile(path.join(root, "VERSION"), "utf8")).trim();
const manifest = JSON.parse(await readFile(path.join(root, "compliance", "RELEASE_MANIFEST.json"), "utf8"));
const cname = (await readFile(path.join(root, "CNAME"), "utf8")).trim();
const migrations = (await readdir(path.join(root, "supabase", "migrations"))).filter(name => name.endsWith(".sql")).sort();
const latestSchema = migrations.at(-1)?.split("_")[0];
const checks = {
  semantic_version_matches: version === manifest.version && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version),
  schema_version_matches: latestSchema === manifest.schema_version,
  cname_intact: cname === "app.piloz.fr",
  no_false_certification: manifest.certification_claim === false && manifest.nf525_certified === false
    && manifest.nf203_certified === false && manifest.afnor_conformity_validated === false,
  production_dependencies_honest: manifest.kms_configured === false && manifest.approved_platform_configured === false,
};
const failed = Object.entries(checks).filter(([,ok]) => !ok).map(([name]) => name);
console.log(JSON.stringify({ ok: failed.length === 0, version, schema_version: latestSchema, checks, failed }));
if (failed.length) process.exitCode = 1;
