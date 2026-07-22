import assert from "node:assert/strict";
import { bundleFileLoader, postgresJsonbText, sha256, verifyFiscalArchive } from "../scripts/lib/fiscal-archive.mjs";

const event = {
  sequence_number: 7,
  previous_hash: "previous",
  payload: { amount: 120, currency: "EUR" },
  payload_hash: "",
  verification_material: "7|payment_recorded|payment|id|material",
  event_hash: "",
};
event.payload_hash = sha256(postgresJsonbText(event.payload));
event.event_hash = sha256(event.verification_material);
const records = { format: "piloz-fiscal-records", events: [event] };
const recordsText = postgresJsonbText(records);
const manifest = {
  format: "piloz-fiscal-archive",
  format_version: "1.0",
  archive_id: "00000000-0000-4000-8000-000000000001",
  archive_number: "ARC-2026-0001",
  items: [{
    relative_path: "data/fiscal-records.json",
    category: "structured_data",
    media_type: "application/json",
    canonicalization: "postgres-jsonb-text-v1",
    content_status: "embedded",
    content_hash: sha256(recordsText),
    byte_size: Buffer.byteLength(recordsText),
  }],
};
const bundle = {
  format: "piloz-fiscal-archive",
  format_version: "1.0",
  manifest,
  manifest_hash: sha256(postgresJsonbText(manifest)),
  signature: { status: "not_configured" },
  files: [{ relative_path: "data/fiscal-records.json", encoding: "json", content: records }],
};

const valid = await verifyFiscalArchive(bundle, bundleFileLoader(bundle));
assert.equal(valid.integrity_valid, true);
assert.equal(valid.signature_valid, null);
assert.equal(valid.checked_events, 1);
assert.equal(valid.warnings[0].code, "SIGNATURE_NOT_CONFIGURED");

const altered = structuredClone(bundle);
altered.files[0].content.events[0].payload.amount = 999;
const invalid = await verifyFiscalArchive(altered, bundleFileLoader(altered));
assert.equal(invalid.integrity_valid, false);
assert.ok(invalid.anomalies.some(item => item.code === "FILE_HASH_MISMATCH"));
assert.ok(invalid.anomalies.some(item => item.code === "EVENT_PAYLOAD_HASH_MISMATCH"));

console.log(JSON.stringify({ ok: true, checks: 7, tampering_detected: true, unsigned_state_explicit: true }));
