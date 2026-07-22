#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { stat } from "node:fs/promises";
import path from "node:path";
import { bundleFileLoader, directoryFileLoader, verifyFiscalArchive } from "./lib/fiscal-archive.mjs";

const input = process.argv[2];
const reportPath = process.argv.find(value => value.startsWith("--report="))?.slice(9);
if (!input) {
  console.error("Usage : node scripts/verify-fiscal-archive.mjs <archive.json|répertoire> [--report=rapport.json]");
  process.exit(64);
}

try {
  const info = await stat(input);
  let envelope;
  let loader;
  if (info.isDirectory()) {
    envelope = JSON.parse(await readFile(path.join(input, "manifest.json"), "utf8"));
    loader = directoryFileLoader(input);
  } else {
    envelope = JSON.parse(await readFile(input, "utf8"));
    loader = bundleFileLoader(envelope);
  }
  const report = await verifyFiscalArchive(envelope, loader);
  const rendered = JSON.stringify(report, null, 2);
  if (reportPath) await writeFile(reportPath, rendered + "\n", "utf8");
  console.log(rendered);
  process.exitCode = report.integrity_valid ? 0 : 2;
} catch (error) {
  console.error(JSON.stringify({ integrity_valid: false, code: "ARCHIVE_UNREADABLE", message: error.message }, null, 2));
  process.exitCode = 2;
}
