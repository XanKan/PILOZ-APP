export type ConnectorResult<T = Record<string, unknown>> = {
  ok: boolean;
  simulation: boolean;
  data?: T;
  errorCode?: string;
  retryable?: boolean;
};

export interface AccreditedPlatformConnector {
  readonly code: string;
  readonly environment: "sandbox" | "production";
  readonly simulation: boolean;
  checkConfiguration(): Promise<ConnectorResult>;
  resolveRecipient(invoice: Record<string, unknown>): Promise<ConnectorResult>;
  sendInvoice(invoice: Uint8Array, idempotencyKey: string): Promise<ConnectorResult>;
  receiveInvoice(externalId: string): Promise<ConnectorResult>;
  getStatus(externalId: string): Promise<ConnectorResult>;
  sendStatus(externalId: string, status: string, idempotencyKey: string): Promise<ConnectorResult>;
  sendEReporting(payload: Record<string, unknown>, idempotencyKey: string): Promise<ConnectorResult>;
  sendPaymentData(payload: Record<string, unknown>, idempotencyKey: string): Promise<ConnectorResult>;
  downloadAttachment(externalId: string, attachmentId: string): Promise<ConnectorResult<Uint8Array>>;
  verifyWebhook(body: Uint8Array, signature: string): Promise<ConnectorResult>;
  retryTransmission(transmissionId: string): Promise<ConnectorResult>;
  cancelTransmission(transmissionId: string): Promise<ConnectorResult>;
}

export function controlledBackoff(attempt: number) {
  const normalized = Math.max(1, Math.min(8, Math.trunc(attempt) || 1));
  return Math.min(3_600_000, 5_000 * 2 ** (normalized - 1));
}

export async function verifyHmacSha256(body: Uint8Array, receivedHex: string, secret: string) {
  if (!secret || !/^[0-9a-f]{64}$/i.test(receivedHex)) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const calculated = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  const received = Uint8Array.from(receivedHex.match(/../g) || [], value => Number.parseInt(value, 16));
  if (calculated.length !== received.length) return false;
  let difference = 0;
  for (let index = 0; index < calculated.length; index += 1) difference |= calculated[index] ^ received[index];
  return difference === 0;
}

export class PilozSimulationConnector implements AccreditedPlatformConnector {
  readonly code = "PILOZ_SANDBOX";
  readonly environment = "sandbox" as const;
  readonly simulation = true;
  private result(action: string): ConnectorResult {
    return { ok: true, simulation: true, data: { action, displayStatus: "Simulation", externalNetwork: false, sentToAdministration: false } };
  }
  async checkConfiguration() { return this.result("check_configuration"); }
  async resolveRecipient() { return this.result("resolve_recipient"); }
  async sendInvoice() { return this.result("send_invoice"); }
  async receiveInvoice() { return this.result("receive_invoice"); }
  async getStatus() { return this.result("get_status"); }
  async sendStatus() { return this.result("send_status"); }
  async sendEReporting() { return this.result("send_e_reporting"); }
  async sendPaymentData() { return this.result("send_payment_data"); }
  async downloadAttachment(): Promise<ConnectorResult<Uint8Array>> { return { ok: false, simulation: true, errorCode: "simulation_has_no_attachment" }; }
  async verifyWebhook(): Promise<ConnectorResult> { return { ok: false, simulation: true, errorCode: "simulation_webhooks_disabled" }; }
  async retryTransmission() { return this.result("retry_transmission"); }
  async cancelTransmission() { return this.result("cancel_transmission"); }
}

export function productionConnectorUnavailable(): never {
  const error = new Error("Aucune plateforme agréée de production n'est configurée et validée.");
  Object.assign(error, { code: "production_connector_not_configured" });
  throw error;
}
