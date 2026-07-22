import { createHash, createPublicKey, verify as verifySignature } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

const textEncoder = new TextEncoder();

export function sha256(value) {
  const bytes = value instanceof Uint8Array ? value : textEncoder.encode(String(value));
  return createHash("sha256").update(bytes).digest("hex");
}

// PostgreSQL jsonb ordonne d'abord les clés selon leur taille UTF-8 puis selon
// leurs octets. Cette sérialisation permet de recalculer les empreintes
// `jsonb::text` produites par les migrations sans accès à Piloz.
export function postgresJsonbText(value) {
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(postgresJsonbText).join(", ")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort((left, right) => {
      const a = Buffer.from(left, "utf8");
      const b = Buffer.from(right, "utf8");
      return a.length - b.length || Buffer.compare(a, b);
    });
    return `{${keys.map(key => `${JSON.stringify(key)}: ${postgresJsonbText(value[key])}`).join(", ")}}`;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Nombre JSON non fini");
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  return JSON.stringify(String(value));
}

function safeRelativePath(value) {
  const source = String(value || "").replaceAll("\\", "/");
  return source && !source.startsWith("/") && !/^[A-Za-z]:/.test(source)
    && source.split("/").every(part => part && part !== "." && part !== "..");
}

function payloadBytes(content, descriptor) {
  if (descriptor.canonicalization === "postgres-jsonb-text-v1") {
    const parsed = typeof content === "string" ? JSON.parse(content) : content;
    return textEncoder.encode(postgresJsonbText(parsed));
  }
  if (content instanceof Uint8Array) return content;
  return textEncoder.encode(typeof content === "string" ? content : JSON.stringify(content));
}

function verifyEventChain(records, anomalies) {
  const events = Array.isArray(records?.events) ? records.events : [];
  let previousSequence = null;
  let previousHash = null;
  for (const event of events) {
    const label = `événement ${event.sequence_number ?? "?"}`;
    const payloadHash = sha256(postgresJsonbText(event.payload ?? {}));
    if (payloadHash !== event.payload_hash) anomalies.push({ code: "EVENT_PAYLOAD_HASH_MISMATCH", item: label });
    if (!event.verification_material || sha256(event.verification_material) !== event.event_hash) {
      anomalies.push({ code: "EVENT_HASH_MISMATCH", item: label });
    }
    if (previousSequence !== null && Number(event.sequence_number) !== previousSequence + 1) {
      anomalies.push({ code: "EVENT_SEQUENCE_BREAK", item: label });
    }
    if (previousHash !== null && event.previous_hash !== previousHash) {
      anomalies.push({ code: "EVENT_PREVIOUS_HASH_MISMATCH", item: label });
    }
    previousSequence = Number(event.sequence_number);
    previousHash = event.event_hash;
  }
  return events.length;
}

function verifyDetachedSignature(envelope, warnings, anomalies) {
  const signature = envelope.signature || {};
  if (!signature.value || !signature.public_key_pem) {
    warnings.push({ code: "SIGNATURE_NOT_CONFIGURED", message: "Archive intègre mais non signée : validation KMS requise." });
    return null;
  }
  try {
    const algorithm = String(signature.algorithm || "").toUpperCase();
    if (!new Set(["RSA-SHA256", "ECDSA-P256-SHA256"]).has(algorithm)) {
      anomalies.push({ code: "UNSUPPORTED_SIGNATURE_ALGORITHM", algorithm });
      return false;
    }
    const valid = verifySignature(
      "sha256",
      Buffer.from(envelope.manifest_hash, "utf8"),
      createPublicKey(signature.public_key_pem),
      Buffer.from(signature.value, "base64"),
    );
    if (!valid) anomalies.push({ code: "SIGNATURE_INVALID" });
    return valid;
  } catch (error) {
    anomalies.push({ code: "SIGNATURE_VERIFICATION_ERROR", message: error.message });
    return false;
  }
}

export async function verifyFiscalArchive(envelope, fileLoader) {
  const anomalies = [];
  const warnings = [];
  if (!envelope || envelope.format !== "piloz-fiscal-archive" || envelope.format_version !== "1.0") {
    anomalies.push({ code: "UNSUPPORTED_ARCHIVE_FORMAT" });
  }
  const manifest = envelope?.manifest;
  const descriptors = Array.isArray(manifest?.items) ? manifest.items : [];
  const expectedManifestHash = manifest ? sha256(postgresJsonbText(manifest)) : null;
  if (!manifest || expectedManifestHash !== envelope.manifest_hash) {
    anomalies.push({ code: "MANIFEST_HASH_MISMATCH", expected: expectedManifestHash, actual: envelope?.manifest_hash ?? null });
  }

  const seen = new Set();
  let checkedFiles = 0;
  let checkedEvents = 0;
  for (const descriptor of descriptors) {
    const relativePath = descriptor.relative_path;
    if (!safeRelativePath(relativePath) || seen.has(relativePath)) {
      anomalies.push({ code: "UNSAFE_OR_DUPLICATE_PATH", item: relativePath });
      continue;
    }
    seen.add(relativePath);
    if (descriptor.content_status === "missing") {
      anomalies.push({ code: "MISSING_ARCHIVE_ITEM", item: relativePath });
      continue;
    }
    let content;
    try {
      content = await fileLoader(relativePath, descriptor);
    } catch (error) {
      anomalies.push({ code: "FILE_READ_ERROR", item: relativePath, message: error.message });
      continue;
    }
    if (content === undefined || content === null) {
      anomalies.push({ code: "FILE_NOT_INCLUDED", item: relativePath });
      continue;
    }
    const bytes = payloadBytes(content, descriptor);
    checkedFiles += 1;
    if (sha256(bytes) !== descriptor.content_hash) {
      anomalies.push({ code: "FILE_HASH_MISMATCH", item: relativePath });
    }
    if (Number.isFinite(Number(descriptor.byte_size)) && descriptor.byte_size !== null
      && Number(descriptor.byte_size) !== bytes.byteLength) {
      anomalies.push({ code: "FILE_SIZE_MISMATCH", item: relativePath });
    }
    if (descriptor.category === "structured_data") {
      try {
        const records = typeof content === "string" ? JSON.parse(content) : content;
        checkedEvents += verifyEventChain(records, anomalies);
      } catch (error) {
        anomalies.push({ code: "STRUCTURED_DATA_INVALID", item: relativePath, message: error.message });
      }
    }
  }
  const signatureValid = verifyDetachedSignature(envelope, warnings, anomalies);
  return {
    format: envelope?.format ?? null,
    archive_id: manifest?.archive_id ?? null,
    archive_number: manifest?.archive_number ?? null,
    integrity_valid: anomalies.length === 0,
    signature_valid: signatureValid,
    compliance_claim: false,
    checked_files: checkedFiles,
    checked_events: checkedEvents,
    anomalies,
    warnings,
    verified_at: new Date().toISOString(),
  };
}

export function bundleFileLoader(envelope) {
  const files = new Map((envelope.files || []).map(file => [file.relative_path, file]));
  return async relativePath => {
    const file = files.get(relativePath);
    if (!file) return null;
    if (file.encoding === "base64") return Buffer.from(file.content || "", "base64");
    return file.content;
  };
}

export function directoryFileLoader(rootDirectory) {
  const root = path.resolve(rootDirectory);
  return async relativePath => {
    const target = path.resolve(root, relativePath);
    if (target !== root && !target.startsWith(root + path.sep)) throw new Error("Chemin hors archive");
    return new Uint8Array(await readFile(target));
  };
}
