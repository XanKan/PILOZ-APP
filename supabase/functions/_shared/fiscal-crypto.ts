import {
  DescribeKeyCommand,
  KMSClient,
  SignCommand,
  VerifyCommand,
  type SigningAlgorithmSpec,
} from "npm:@aws-sdk/client-kms@3";

export type FiscalSignature = {
  algorithm: string;
  keyId: string;
  signatureBase64: string;
};

export type FiscalSignerStatus = {
  configured: boolean;
  provider: string;
  keyId?: string;
  algorithm?: string;
  reason?: string;
};

export type FiscalSigner = {
  status(): Promise<FiscalSignerStatus>;
  signDigest(hexDigest: string): Promise<FiscalSignature>;
  verifyDigest(hexDigest: string, signature: FiscalSignature): Promise<boolean>;
};

const ALLOWED_AWS_ALGORITHMS = new Set<SigningAlgorithmSpec>([
  "RSASSA_PSS_SHA_256",
  "ECDSA_SHA_256",
]);

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, item]) => [key, sorted(item)]),
    );
  }
  return value;
}

function readSecret(name: string): string {
  return Deno.env.get(name)?.trim() || "";
}

function digestBytes(hexDigest: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/i.test(hexDigest)) throw new Error("INVALID_SHA256_DIGEST");
  return Uint8Array.from(hexDigest.match(/.{2}/g) || [], pair => Number.parseInt(pair, 16));
}

function cryptoBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error("INVALID_KMS_SIGNATURE");
  const binary = atob(value);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

export function canonicalizeFiscalPayload(value: unknown): string {
  return JSON.stringify(sorted(value));
}

export async function sha256Hex(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", cryptoBuffer(bytes));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

export class KmsRequiredSigner implements FiscalSigner {
  async status(): Promise<FiscalSignerStatus> {
    return { configured: false, provider: "none", reason: "KMS_NOT_CONFIGURED" };
  }
  async signDigest(_hexDigest: string): Promise<FiscalSignature> {
    throw new Error("KMS_NOT_CONFIGURED");
  }
  async verifyDigest(_hexDigest: string, _signature: FiscalSignature): Promise<boolean> {
    throw new Error("KMS_NOT_CONFIGURED");
  }
}

export class AwsKmsSigner implements FiscalSigner {
  private readonly keyId = readSecret("FISCAL_KMS_KEY_ID");
  private readonly region = readSecret("FISCAL_KMS_AWS_REGION") || "eu-west-3";
  private readonly algorithm = (readSecret("FISCAL_KMS_SIGNING_ALGORITHM") ||
    "RSASSA_PSS_SHA_256") as SigningAlgorithmSpec;
  private readonly accessKeyId = readSecret("FISCAL_KMS_AWS_ACCESS_KEY_ID");
  private readonly secretAccessKey = readSecret("FISCAL_KMS_AWS_SECRET_ACCESS_KEY");
  private readonly sessionToken = readSecret("FISCAL_KMS_AWS_SESSION_TOKEN");

  private client(): KMSClient {
    if (!this.accessKeyId || !this.secretAccessKey) throw new Error("KMS_AWS_CREDENTIALS_MISSING");
    return new KMSClient({
      region: this.region,
      credentials: {
        accessKeyId: this.accessKeyId,
        secretAccessKey: this.secretAccessKey,
        ...(this.sessionToken ? { sessionToken: this.sessionToken } : {}),
      },
    });
  }

  async status(): Promise<FiscalSignerStatus> {
    if (!this.keyId) return { configured: false, provider: "aws-kms", reason: "KMS_KEY_ID_MISSING" };
    if (!this.accessKeyId || !this.secretAccessKey) {
      return { configured: false, provider: "aws-kms", keyId: this.keyId, reason: "KMS_AWS_CREDENTIALS_MISSING" };
    }
    if (!ALLOWED_AWS_ALGORITHMS.has(this.algorithm)) {
      return { configured: false, provider: "aws-kms", keyId: this.keyId, reason: "KMS_ALGORITHM_NOT_ALLOWED" };
    }
    try {
      const response = await this.client().send(new DescribeKeyCommand({ KeyId: this.keyId }));
      const metadata = response.KeyMetadata;
      const algorithmAvailable = metadata?.SigningAlgorithms?.includes(this.algorithm);
      if (!metadata?.Enabled || metadata.KeyUsage !== "SIGN_VERIFY" || !algorithmAvailable) {
        return {
          configured: false,
          provider: "aws-kms",
          keyId: metadata?.Arn || this.keyId,
          algorithm: this.algorithm,
          reason: "KMS_KEY_NOT_READY_FOR_SIGNING",
        };
      }
      return {
        configured: true,
        provider: "aws-kms",
        keyId: metadata.Arn || this.keyId,
        algorithm: this.algorithm,
      };
    } catch (error) {
      console.error("fiscal_kms_status_failed", { code: error instanceof Error ? error.name : "unknown" });
      return { configured: false, provider: "aws-kms", keyId: this.keyId, reason: "KMS_UNREACHABLE" };
    }
  }

  async signDigest(hexDigest: string): Promise<FiscalSignature> {
    const status = await this.status();
    if (!status.configured || !status.keyId || !status.algorithm) throw new Error(status.reason || "KMS_NOT_CONFIGURED");
    const response = await this.client().send(new SignCommand({
      KeyId: status.keyId,
      Message: digestBytes(hexDigest),
      MessageType: "DIGEST",
      SigningAlgorithm: status.algorithm as SigningAlgorithmSpec,
    }));
    if (!response.Signature) throw new Error("KMS_EMPTY_SIGNATURE");
    return {
      algorithm: status.algorithm,
      keyId: status.keyId,
      signatureBase64: bytesToBase64(response.Signature),
    };
  }

  async verifyDigest(hexDigest: string, signature: FiscalSignature): Promise<boolean> {
    if (!ALLOWED_AWS_ALGORITHMS.has(signature.algorithm as SigningAlgorithmSpec)) {
      throw new Error("KMS_ALGORITHM_NOT_ALLOWED");
    }
    const response = await this.client().send(new VerifyCommand({
      KeyId: signature.keyId,
      Message: digestBytes(hexDigest),
      MessageType: "DIGEST",
      SigningAlgorithm: signature.algorithm as SigningAlgorithmSpec,
      Signature: base64ToBytes(signature.signatureBase64),
    }));
    return response.SignatureValid === true;
  }
}

// La clé privée reste dans le KMS. Seuls l'identifiant de clé et des
// identifiants IAM limités à Sign/Verify/DescribeKey sont lus côté serveur.
export function createFiscalSigner(): FiscalSigner {
  const provider = readSecret("FISCAL_KMS_PROVIDER").toLowerCase();
  if (!provider) return new KmsRequiredSigner();
  if (provider === "aws" || provider === "aws-kms") return new AwsKmsSigner();
  throw new Error("UNSUPPORTED_FISCAL_KMS_PROVIDER");
}

export const fiscalSigner: FiscalSigner = createFiscalSigner();
