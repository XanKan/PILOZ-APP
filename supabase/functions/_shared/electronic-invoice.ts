export type ElectronicFormat = "ubl" | "cii" | "facturx";

export type VerifiedFormatProfile = {
  id: string;
  format: ElectronicFormat;
  profile_code: string;
  profile_version: string;
  xsd_storage_path: string;
  schematron_storage_path?: string | null;
  artifact_hashes: Record<string, string>;
  validation_status: "verified";
};

export type FormatValidationReport = {
  status: "valid" | "invalid" | "blocked";
  format: ElectronicFormat;
  profileCode?: string;
  errors: Array<{ code: string; message: string; location?: string }>;
  warnings: Array<{ code: string; message: string }>;
  validatorName: string;
  validatorVersion: string;
};

export interface ElectronicInvoiceAdapter {
  readonly format: ElectronicFormat;
  generate(canonicalInvoice: Record<string, unknown>, profile: VerifiedFormatProfile): Promise<Uint8Array>;
  validate(artifact: Uint8Array, profile: VerifiedFormatProfile): Promise<FormatValidationReport>;
}

export class ElectronicProfileUnavailableError extends Error {
  readonly code = "official_profile_not_configured";
  constructor(readonly format: ElectronicFormat) {
    super(`Le profil officiel ${format.toUpperCase()} et ses validateurs ne sont pas installés.`);
  }
}

// Registre volontairement vide. Une implémentation ne peut être ajoutée
// qu'avec les artefacts officiels, leurs empreintes et des tests XSD/
// Schematron reproductibles. Aucun XML approximatif n'est produit.
const adapters = new Map<ElectronicFormat, ElectronicInvoiceAdapter>();

export function registerVerifiedAdapter(adapter: ElectronicInvoiceAdapter) {
  adapters.set(adapter.format, adapter);
}

export function requireVerifiedAdapter(format: ElectronicFormat) {
  const adapter = adapters.get(format);
  if (!adapter) throw new ElectronicProfileUnavailableError(format);
  return adapter;
}

export function listAdapterReadiness() {
  return (["ubl", "cii", "facturx"] as ElectronicFormat[]).map(format => ({
    format,
    ready: adapters.has(format),
    status: adapters.has(format) ? "adapter_registered_requires_profile_check" : "official_profile_not_configured",
  }));
}
