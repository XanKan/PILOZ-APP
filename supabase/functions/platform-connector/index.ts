import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

type JsonObject = Record<string, unknown>;
type RequestBody = {
  action?: string;
  companyId?: string;
  documentId?: string;
  exchangeId?: string;
  recordId?: string;
  operation?: string;
  idempotencyKey?: string;
  confirmation?: string;
  statusCode?: string;
  reasonCode?: string;
  note?: string;
};

const SUPERPDP_API_URL = "https://api.superpdp.tech";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const STORAGE_BUCKET = "company-files";

function safeUuid(value: unknown) {
  const normalized = String(value || "").trim();
  return UUID.test(normalized) ? normalized : "";
}

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(...values: unknown[]) {
  for (const value of values) {
    const candidate = String(value ?? "").trim();
    if (candidate) return candidate;
  }
  return "";
}

function decimal(value: unknown, absolute = false) {
  const number = Number(value || 0);
  return (absolute ? Math.abs(number) : number).toFixed(2);
}

function integer(value: unknown, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : fallback;
}

function environment() {
  return text(Deno.env.get("SUPERPDP_ENVIRONMENT"), "sandbox").toLowerCase();
}

function assertSandboxConfiguration() {
  if (environment() !== "sandbox") {
    throw Object.assign(new Error("superpdp_sandbox_required"), { status: 503 });
  }
}

async function responsePayload(response: Response) {
  if (response.status === 204 || response.status === 205) return null;
  const body = await response.text();
  if (!body.trim()) return null;
  const contentType = (response.headers.get("content-type") || "").toLowerCase();
  if (!contentType.includes("json")) return { text: body, contentType };
  try { return JSON.parse(body); }
  catch { throw Object.assign(new Error("superpdp_invalid_json_response"), { status: 502 }); }
}

async function responseBytes(response: Response) {
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (!response.ok || !bytes.length) {
    throw Object.assign(new Error("superpdp_empty_binary_response"), { status: 502 });
  }
  return { bytes, contentType: response.headers.get("content-type") || "application/octet-stream" };
}

async function sha256(value: Uint8Array | string) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", buffer)))
    .map(part => part.toString(16).padStart(2, "0")).join("");
}

async function superPdpToken() {
  assertSandboxConfiguration();
  const clientId = Deno.env.get("SUPERPDP_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("SUPERPDP_CLIENT_SECRET") || "";
  if (!clientId || !clientSecret) throw Object.assign(new Error("superpdp_credentials_not_configured"), { status: 503 });
  const request = async (useBasic: boolean) => {
    const headers: Record<string, string> = { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" };
    const values: Record<string, string> = { grant_type: "client_credentials" };
    if (useBasic) headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
    else Object.assign(values, { client_id: clientId, client_secret: clientSecret });
    const response = await fetch(`${SUPERPDP_API_URL}/oauth2/token`, { method: "POST", headers, body: new URLSearchParams(values) });
    return { response, payload: object(await responsePayload(response)) };
  };
  let result = await request(true);
  if (!result.response.ok || !result.payload.access_token) result = await request(false);
  if (!result.response.ok || !result.payload.access_token) {
    throw Object.assign(new Error("superpdp_authentication_failed"), { status: result.response.status === 401 ? 401 : 502 });
  }
  return String(result.payload.access_token);
}

async function superPdpRequest(path: string, accessToken: string, init: RequestInit = {}) {
  const response = await fetch(`${SUPERPDP_API_URL}${path}`, {
    ...init,
    headers: { Accept: "application/json", Authorization: `Bearer ${accessToken}`, ...(init.headers || {}) },
  });
  return { response, payload: await responsePayload(response) };
}

async function superPdpBinary(path: string, accessToken: string, accept: string, init: RequestInit = {}, failureCode = "superpdp_binary_request_failed") {
  const response = await fetch(`${SUPERPDP_API_URL}${path}`, {
    ...init,
    headers: { Accept: accept, Authorization: `Bearer ${accessToken}`, ...(init.headers || {}) },
  });
  if (!response.ok) {
    const payload = await responsePayload(response);
    console.error("[PILOZ SUPER PDP] réponse binaire refusée", { path, status: response.status, payload });
    throw Object.assign(new Error(failureCode), { status: response.status >= 400 && response.status < 500 ? 409 : 502 });
  }
  return responseBytes(response);
}

async function requireElectronicInvoiceManager(userClient: SupabaseClient, companyId: string) {
  const { data, error } = await userClient.rpc("has_company_permission", {
    target_company_id: companyId,
    target_permission: "electronic_invoice_manage",
  });
  if (error || data !== true) throw Object.assign(new Error("forbidden"), { status: 403 });
}

async function requirePurchaseInvoiceReviewer(userClient: SupabaseClient, companyId: string) {
  const [purchase, electronic] = await Promise.all([
    userClient.rpc("has_company_permission", {
      target_company_id: companyId,
      target_permission: "purchases.invoices.write",
    }),
    userClient.rpc("has_company_permission", {
      target_company_id: companyId,
      target_permission: "electronic_invoice_manage",
    }),
  ]);
  if (purchase.data !== true && electronic.data !== true) {
    throw Object.assign(new Error("forbidden_purchase_invoice_review"), { status: 403 });
  }
}

function safeCompany(value: unknown) {
  const company = object(value);
  return {
    id: Number(company.id) || null,
    environment: text(company.env),
    numberScheme: text(company.number_scheme),
    number: text(company.number),
    formalName: text(company.formal_name),
    tradeName: text(company.trade_name),
    city: text(company.city),
    country: text(company.country),
  };
}

async function verifiedSandbox(token: string) {
  assertSandboxConfiguration();
  const check = await superPdpRequest("/v1.beta/companies/me", token);
  const company = safeCompany(check.payload);
  if (!check.response.ok) throw Object.assign(new Error("superpdp_company_check_failed"), { status: 502 });
  if (company.environment !== "sandbox") throw Object.assign(new Error("superpdp_account_is_not_sandbox"), { status: 409 });
  return { company, raw: object(check.payload) };
}

async function connectorFor(adminClient: SupabaseClient, companyId: string) {
  const { data, error } = await adminClient.from("platform_connectors").select("*")
    .eq("company_id", companyId).eq("connector_code", "SUPERPDP").eq("environment", "sandbox")
    .order("updated_at", { ascending: false }).limit(1).maybeSingle();
  if (error || !data) throw Object.assign(new Error("superpdp_connector_not_configured"), { status: 409 });
  if (data.production_enabled || data.environment !== "sandbox") {
    throw Object.assign(new Error("superpdp_sandbox_required"), { status: 409 });
  }
  return data as JsonObject;
}

async function testSuperPdp(userClient: SupabaseClient, companyId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  const verified = await verifiedSandbox(token);
  const { data: connectorId, error } = await userClient.rpc("configure_superpdp_sandbox_connector", {
    target_company_id: companyId,
    target_external_company: verified.raw,
  });
  if (error) throw Object.assign(new Error("superpdp_connector_registration_failed"), { status: 409 });
  return { ok: true, connectorId, provider: "SUPER PDP", environment: "sandbox", appEnvironment: "production", company: verified.company };
}

async function sendSuperPdpTestInvoice(userClient: SupabaseClient, companyId: string, confirmation: string) {
  if (confirmation !== "SEND_SUPERPDP_SANDBOX_TEST") throw Object.assign(new Error("superpdp_test_confirmation_required"), { status: 400 });
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  await verifiedSandbox(token);
  const generated = await superPdpBinary("/v1.beta/invoices/generate_test_invoice?format=factur-x", token, "application/pdf");
  const externalId = `PILOZ-TEST-${crypto.randomUUID().slice(0, 24)}`.slice(0, 36);
  const sent = await superPdpRequest(`/v1.beta/invoices?external_id=${encodeURIComponent(externalId)}`, token, {
    method: "POST", headers: { "Content-Type": "application/pdf" }, body: generated.bytes,
  });
  if (!sent.response.ok) throw Object.assign(new Error("superpdp_test_invoice_send_failed"), { status: 502 });
  const result = object(sent.payload);
  const { data: transmissionId, error } = await userClient.rpc("record_superpdp_sandbox_test_transmission", {
    target_company_id: companyId,
    target_external_id: externalId,
    target_external_invoice_id: result.id == null ? "" : String(result.id),
  });
  if (error) throw Object.assign(new Error("superpdp_test_audit_failed"), { status: 409 });
  return { ok: true, provider: "SUPER PDP", environment: "sandbox", externalId, invoiceId: Number(result.id) || null, transmissionId };
}

async function sandboxRoutedInvoice(token: string, invoice: JsonObject) {
  // A SUPER PDP sandbox token is bound to one of their fictitious companies.
  // Real French companies are not registered in the sandbox Peppol directory,
  // so an otherwise valid production invoice would be rejected at routing time.
  // SUPER PDP exposes a generated EN16931 invoice containing the token company
  // and a valid sandbox recipient. Only these two parties are substituted; the
  // Piloz invoice number, dates, lines, taxes and totals stay unchanged.
  const generated = await superPdpRequest("/v1.beta/invoices/generate_test_invoice?format=en16931", token);
  const envelope = object(generated.payload);
  const template = object(envelope.en_invoice || envelope.invoice || generated.payload);
  const seller = object(template.seller), buyer = object(template.buyer);
  if (!generated.response.ok || !Object.keys(seller).length || !Object.keys(buyer).length) {
    console.error("[PILOZ SUPER PDP] routage sandbox indisponible", {
      status: generated.response.status,
      providerCode: text(envelope.code),
      providerMessage: text(envelope.message).slice(0, 240),
    });
    throw Object.assign(new Error("superpdp_sandbox_routing_failed"), { status: 502 });
  }
  return {
    invoice: compactJson({ ...invoice, seller, buyer }) as JsonObject,
    routing: {
      seller: { name: partyName(seller), electronic_address: object(seller.electronic_address) },
      buyer: { name: partyName(buyer), electronic_address: object(buyer.electronic_address) },
    },
  };
}

function countryCode(party: JsonObject) {
  return text(party.country_code, party.country, "FR").slice(0, 2).toUpperCase();
}

function postalAddress(party: JsonObject) {
  return {
    address_line1: text(party.address_line_1, party.address, party.address_line1),
    address_line2: text(party.address_line_2, party.address_line2),
    post_code: text(party.postal_code, party.post_code),
    city: text(party.city),
    country_code: countryCode(party),
  };
}

function partyName(party: JsonObject) {
  return text(party.legal_name, party.trade_name, [party.first_name, party.last_name].filter(Boolean).join(" "), party.name);
}

function electronicAddress(party: JsonObject, fallbackScheme = "", fallbackValue = "") {
  // The SUPER PDP sandbox exposes an internal company number with the literal
  // scheme `sandbox`. It identifies the API tenant, but it is not an ISO 6523
  // electronic address and must never be written to BT-34/BT-49.
  const normalizedFallbackScheme = text(fallbackScheme).trim();
  const usableProviderFallback = /^\d{4}$/.test(normalizedFallbackScheme) && Boolean(text(fallbackValue));
  const value = text(
    party.routing_identifier,
    party.electronic_routing_identifier,
    usableProviderFallback ? fallbackValue : "",
    party.siret,
    party.siren,
  );
  const scheme = text(
    party.routing_scheme,
    party.electronic_routing_scheme,
    usableProviderFallback ? normalizedFallbackScheme : "",
    digits(party.siret).length === 14 ? "0009" : "0002",
  );
  return value ? { value, scheme } : null;
}

function vatCategory(rate: number, issuer: JsonObject) {
  if (rate > 0) return "S";
  const liable = issuer.vat_liable ?? issuer.subject_to_vat ?? issuer.vat_registered;
  return liable === false ? "O" : "Z";
}

function digits(value: unknown) {
  return text(value).replace(/\D/g, "");
}

function sirenIdentifier(party: JsonObject) {
  const direct = digits(party.siren);
  const fromSiret = digits(party.siret).slice(0, 9);
  const value = direct.length === 9 ? direct : fromSiret.length === 9 ? fromSiret : "";
  return value ? { value, scheme: "0002" } : undefined;
}

function privatePartyIdentifiers(party: JsonObject) {
  const siret = digits(party.siret);
  return siret.length === 14 ? [{ value: siret, scheme: "0009" }] : undefined;
}

function normalizedBusinessText(value: unknown) {
  return text(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function billingProcessCode(invoice: JsonObject, lines: JsonObject[], totals: JsonObject, references: unknown) {
  const operation = normalizedBusinessText(invoice.operation_category);
  const lineTypes = lines.map(line => normalizedBusinessText(line.item_type || line.product_type || line.line_nature)).join(" ");
  const source = `${operation} ${lineTypes}`;
  const hasGoods = /\b(bien|biens|article|articles|produit|produits|marchandise|marchandises|goods?)\b/.test(source);
  const hasServices = /\b(service|services|prestation|prestations|main.?d.?oeuvre|abonnement|subscription)\b/.test(source);
  const family = hasGoods && hasServices ? "M" : hasGoods ? "B" : "S";
  const paid = Math.abs(Number(totals.paid || 0));
  const inclTax = Math.abs(Number(totals.incl_tax || 0));
  if (inclTax > 0 && paid >= inclTax - 0.005) return `${family}2`;
  const hasDeposit = invoice.type === "balance_invoice" || array(references).some(reference => {
    const link = object(reference);
    return /deposit|acompte/.test(normalizedBusinessText(link.link_type || link.document_type));
  });
  return `${family}${hasDeposit ? "4" : "1"}`;
}

function compactJson(value: unknown): unknown {
  if (Array.isArray(value)) {
    const compacted = value.map(compactJson).filter(item => item !== undefined);
    return compacted.length ? compacted : undefined;
  }
  if (value && typeof value === "object") {
    const compacted = Object.fromEntries(Object.entries(value as JsonObject)
      .map(([key, item]) => [key, compactJson(item)] as const)
      .filter(([, item]) => item !== undefined));
    return Object.keys(compacted).length ? compacted : undefined;
  }
  if (value === undefined || value === null || (typeof value === "string" && value.trim() === "")) return undefined;
  return value;
}

function unitCode(value: unknown) {
  const raw = text(value, "C62").trim();
  const normalized = raw.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[.\s_-]+/g, "");
  const aliases: Record<string, string> = {
    unite: "C62", unit: "C62", piece: "C62", pcs: "C62",
    heure: "HUR", heures: "HUR", hour: "HUR", hours: "HUR", h: "HUR",
    jour: "DAY", jours: "DAY", day: "DAY", days: "DAY",
    mois: "MON", month: "MON", months: "MON",
    annee: "ANN", annees: "ANN", year: "ANN", years: "ANN",
    metre: "MTR", metres: "MTR", m: "MTR",
    m2: "MTK", metrecarre: "MTK", metrescarres: "MTK",
    m3: "MTQ", metrecube: "MTQ", metrescubes: "MTQ",
    kg: "KGM", kilogramme: "KGM", kilogrammes: "KGM",
    g: "GRM", gramme: "GRM", grammes: "GRM",
    litre: "LTR", litres: "LTR", l: "LTR",
    forfait: "LS"
  };
  if (aliases[normalized]) return aliases[normalized];
  const candidate = raw.toUpperCase();
  return /^[A-Z0-9]{1,3}$/.test(candidate) ? candidate : "C62";
}

function invoiceTypeCode(type: unknown) {
  const value = text(type).toLowerCase();
  if (value === "credit_note") return 381;
  if (value === "deposit_invoice") return 386;
  return 380;
}

function canonicalToEn16931(payload: JsonObject, connector: JsonObject) {
  const supplier = object(payload.supplier), customer = object(payload.customer), invoice = object(payload.invoice);
  const totals = object(payload.totals), payment = object(payload.payment), config = object(connector.non_secret_configuration);
  const sellerAddress = electronicAddress(supplier, text(config.external_company_number_scheme), text(config.external_company_number));
  const buyerAddress = electronicAddress(customer);
  if (!sellerAddress) throw Object.assign(new Error("superpdp_seller_electronic_address_required"), { status: 409 });
  if (!buyerAddress) throw Object.assign(new Error("superpdp_buyer_electronic_address_required"), { status: 409 });
  const invoiceLines = array(payload.lines).map(object).filter(line => !["title", "section", "comment", "subtotal"].includes(text(line.line_type)));
  if (!invoiceLines.length) throw Object.assign(new Error("superpdp_invoice_lines_required"), { status: 409 });
  const lines = invoiceLines.map((line, index) => {
    const quantity = Number(line.quantity || 1) || 1;
    const rate = Number(line.tax_rate || 0);
    const category = vatCategory(rate, supplier);
    return {
      identifier: text(line.position, index + 1),
      invoiced_quantity: String(quantity),
      invoiced_quantity_code: unitCode(text(line.unit_code, line.unit, "C62")),
      net_amount: decimal(line.total_excl_tax, true),
      price_details: {
        item_net_price: decimal(line.unit_price, true),
        item_price_base_quantity: "1",
        quantity_unit_code: unitCode(text(line.unit_code, line.unit, "C62")),
      },
      item_information: {
        name: text(line.name, line.description, `Ligne ${index + 1}`),
        description: text(line.description),
        seller_identifier: text(line.reference),
      },
      vat_information: {
        invoiced_item_vat_category_code: category,
        // EN 16931 BR-O-05 forbids BT-152 when VAT is outside scope (O).
        ...(!["O", "E"].includes(category) ? { invoiced_item_vat_rate: String(rate) } : {}),
      },
    };
  });
  const taxes = array(payload.tax_breakdown).map(object).map(row => {
    const rate = Number(row.rate || 0);
    const category = vatCategory(rate, supplier);
    return {
      vat_category_taxable_amount: decimal(row.taxable_amount, true),
      vat_category_tax_amount: decimal(row.tax_amount, true),
      vat_category_code: category,
      ...(!["O", "E"].includes(category) ? { vat_category_rate: String(rate) } : {}),
      ...(category === "O" ? { vat_exemption_reason: "TVA non applicable, art. 293 B du CGI" } : {}),
    };
  });
  if (!taxes.length) {
    const grouped = new Map<number, { taxable: number; tax: number }>();
    for (const line of invoiceLines) {
      const rate = Number(line.tax_rate || 0);
      const current = grouped.get(rate) || { taxable: 0, tax: 0 };
      current.taxable += Math.abs(Number(line.total_excl_tax || 0));
      current.tax += Math.abs(Number(line.total_tax || 0));
      grouped.set(rate, current);
    }
    for (const [rate, amount] of grouped) {
      const category = vatCategory(rate, supplier);
      taxes.push({
        vat_category_taxable_amount: decimal(amount.taxable),
        vat_category_tax_amount: decimal(amount.tax),
        vat_category_code: category,
        ...(!["O", "E"].includes(category) ? { vat_category_rate: String(rate) } : {}),
        ...(category === "O" ? { vat_exemption_reason: "TVA non applicable, art. 293 B du CGI" } : {}),
      });
    }
  }
  const legalMentions = object(payload.legal_mentions);
  const processCode = billingProcessCode(invoice, invoiceLines, totals, payload.references);
  const result: JsonObject = {
    number: text(invoice.number),
    issue_date: text(invoice.issue_date),
    type_code: invoiceTypeCode(invoice.type),
    currency_code: text(invoice.currency, "EUR"),
    process_control: {
      specification_identifier: "urn:cen.eu:en16931:2017",
      business_process_type: processCode,
    },
    notes: [
      { subject_code: "PMT", note: text(legalMentions.collection_fee, "Indemnite forfaitaire pour frais de recouvrement due en cas de retard de paiement : 40 EUR.") },
      { subject_code: "PMD", note: text(legalMentions.late_payment_penalties, "Penalites de retard : trois fois le taux d'interet legal en vigueur.") },
      { subject_code: "AAB", note: text(legalMentions.early_payment_discount, "Escompte pour paiement anticipe : neant.") },
    ],
    seller: {
      name: partyName(supplier), trading_name: text(supplier.trade_name), electronic_address: sellerAddress,
      postal_address: postalAddress(supplier), vat_identifier: text(supplier.vat_number),
      identifiers: privatePartyIdentifiers(supplier),
      legal_registration_identifier: sirenIdentifier(supplier),
    },
    buyer: {
      name: partyName(customer), electronic_address: buyerAddress, postal_address: postalAddress(customer),
      vat_identifier: text(customer.vat_number),
      identifiers: privatePartyIdentifiers(customer),
      legal_registration_identifier: sirenIdentifier(customer),
    },
    totals: {
      sum_invoice_lines_amount: decimal(totals.excl_tax, true),
      total_without_vat: decimal(totals.excl_tax, true),
      // SUPER PDP follows the official EN 16931 `amount` schema here: the
      // numeric member is named `value` (not `amount`). A wrong key makes the
      // Factur-X/CII conversion fail even though the Piloz invoice is valid.
      total_vat_amount: { value: decimal(totals.tax, true), currency_code: text(invoice.currency, "EUR") },
      total_with_vat: decimal(totals.incl_tax, true),
      paid_amount: decimal(totals.paid, true),
      amount_due_for_payment: decimal(totals.payable ?? totals.incl_tax, true),
    },
    vat_break_down: taxes,
    lines,
    payment_due_date: text(invoice.due_date),
    payment_terms: text(payment.terms),
    purchase_order_reference: text(invoice.purchase_order_reference),
    contract_reference: text(invoice.contract_reference),
  };
  return compactJson(result) as JsonObject;
}

async function convertInvoice(token: string, from: "en16931" | "cii", to: "cii" | "factur-x", invoice: JsonObject | Uint8Array, pdf?: Uint8Array) {
  let body: BodyInit, headers: Record<string, string> = {};
  if (to === "factur-x" && pdf) {
    const form = new FormData();
    const pdfBuffer = pdf.buffer.slice(pdf.byteOffset, pdf.byteOffset + pdf.byteLength) as ArrayBuffer;
    form.append("pdf", new Blob([pdfBuffer], { type: "application/pdf" }), "invoice.pdf");
    form.append("invoice", new Blob([JSON.stringify(invoice)], { type: "application/json" }), "invoice.json");
    body = form;
  } else if (from === "en16931") {
    body = JSON.stringify(invoice); headers["Content-Type"] = "application/json";
  } else {
    const bytes = invoice as Uint8Array;
    body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    headers["Content-Type"] = "application/xml";
  }
  return superPdpBinary(`/v1.beta/invoices/convert?from=${from}&to=${to}`, token, to === "factur-x" ? "application/pdf" : "application/xml", { method: "POST", headers, body }, "superpdp_invoice_conversion_failed");
}

async function storageUpload(adminClient: SupabaseClient, path: string, bytes: Uint8Array, contentType: string) {
  const { error } = await adminClient.storage.from(STORAGE_BUCKET).upload(path, bytes, { contentType, upsert: false });
  if (error && !/already exists|duplicate/i.test(error.message)) throw Object.assign(new Error("superpdp_artifact_storage_failed"), { status: 502 });
  return path;
}

async function downloadStored(adminClient: SupabaseClient, path: string) {
  const { data, error } = await adminClient.storage.from(STORAGE_BUCKET).download(path);
  if (error || !data) throw Object.assign(new Error("final_pdf_unavailable"), { status: 409 });
  return new Uint8Array(await data.arrayBuffer());
}

async function sendDocument(userClient: SupabaseClient, adminClient: SupabaseClient, companyId: string, documentId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  await verifiedSandbox(token);
  const connector = await connectorFor(adminClient, companyId);
  const { data: document, error: documentError } = await adminClient.from("documents").select("*")
    .eq("id", documentId).eq("company_id", companyId).maybeSingle();
  if (documentError || !document) throw Object.assign(new Error("document_not_found"), { status: 404 });
  if (!["invoice", "deposit_invoice", "balance_invoice", "credit_note"].includes(document.document_type) || !document.finalized_at) {
    throw Object.assign(new Error("finalized_fiscal_document_required"), { status: 409 });
  }
  if (!document.final_pdf_path || document.pdf_status !== "ready") throw Object.assign(new Error("final_pdf_unavailable"), { status: 409 });
  const existing = await adminClient.from("superpdp_invoice_exchanges").select("*")
    .eq("company_id", companyId).eq("document_id", documentId).eq("direction", "outgoing").maybeSingle();
  if (existing.error) throw Object.assign(new Error("superpdp_exchange_audit_failed"), { status: 502 });
  if (existing.data) return { ok: true, idempotent: true, environment: "sandbox", exchange: existing.data };

  let recordId = safeUuid(document.electronic_invoice_record_id);
  let record: JsonObject | null = null;
  if (recordId) {
    const reusable = await adminClient.from("electronic_invoice_records").select("*")
      .eq("id", recordId).eq("company_id", companyId).eq("document_id", documentId).maybeSingle();
    if (!reusable.error && reusable.data?.validation_status === "valid") record = reusable.data;
    else recordId = "";
  }
  if (!recordId) {
    const canonicalResult = await userClient.rpc("create_canonical_invoice_record", { target_document_id: documentId });
    if (canonicalResult.error) throw Object.assign(new Error("canonical_invoice_failed"), { status: 409 });
    recordId = safeUuid(object(canonicalResult.data).record_id);
    if (!recordId || object(canonicalResult.data).status !== "valid") {
      throw Object.assign(new Error("canonical_invoice_invalid"), { status: 409, detail: canonicalResult.data });
    }
    const created = await adminClient.from("electronic_invoice_records").select("*").eq("id", recordId).single();
    record = created.data;
    if (created.error || !record) throw Object.assign(new Error("canonical_invoice_failed"), { status: 409 });
  }
  if (!record) throw Object.assign(new Error("canonical_invoice_failed"), { status: 409 });
  const canonicalPayload = object(record.canonical_payload);
  const { data: documentSettings } = await adminClient.from("company_document_settings")
    .select("early_payment_discount_notice,late_payment_penalty_notice,collection_fee_notice")
    .eq("company_id", companyId).maybeSingle();
  canonicalPayload.legal_mentions = {
    early_payment_discount: text(documentSettings?.early_payment_discount_notice),
    late_payment_penalties: text(documentSettings?.late_payment_penalty_notice),
    collection_fee: text(documentSettings?.collection_fee_notice),
  };
  const enInvoice = canonicalToEn16931(canonicalPayload, connector);
  // The legal Piloz PDF remains immutable and keeps its real parties. The
  // sandbox artifact is rendered separately with SUPER PDP test parties so it
  // cannot be mistaken for, or overwrite, the production document.
  const sandbox = await sandboxRoutedInvoice(token, enInvoice);
  const transmittedInvoice = sandbox.invoice;
  const cii = await convertInvoice(token, "en16931", "cii", transmittedInvoice);
  const facturx = await convertInvoice(token, "en16931", "factur-x", transmittedInvoice);
  const externalId = `PILOZ-${documentId}`.slice(0, 36);
  const sent = await superPdpRequest(`/v1.beta/invoices?external_id=${encodeURIComponent(externalId)}`, token, {
    method: "POST", headers: { "Content-Type": "application/pdf" }, body: facturx.bytes,
  });
  if (!sent.response.ok) {
    console.error("[PILOZ SUPER PDP] envoi sandbox refusé", { status: sent.response.status, payload: sent.payload, documentId });
    const refusal = object(sent.payload);
    throw Object.assign(new Error("superpdp_invoice_send_failed"), {
      status: sent.response.status >= 400 && sent.response.status < 500 ? 409 : 502,
      provider: { code: refusal.code, message: text(refusal.message).slice(0, 240) },
    });
  }
  const provider = object(sent.payload), providerId = text(provider.id, provider.invoice_id, provider.uuid);
  const base = `${companyId}/electronic-invoices/sandbox/outgoing/${documentId}/${recordId}`;
  const pdfPath = await storageUpload(adminClient, `${base}.factur-x.pdf`, facturx.bytes, "application/pdf");
  const xmlPath = await storageUpload(adminClient, `${base}.cii.xml`, cii.bytes, "application/xml");
  const [pdfHash, xmlHash, requestHash, responseHash] = await Promise.all([
    sha256(facturx.bytes), sha256(cii.bytes), sha256(JSON.stringify(transmittedInvoice)), sha256(JSON.stringify(provider)),
  ]);
  const { data: transmission, error: transmissionError } = await adminClient.from("platform_transmissions").insert({
    company_id: companyId, connector_id: connector.id, electronic_invoice_record_id: recordId,
    operation: "send_invoice", idempotency_key: externalId, status: "succeeded", is_simulation: false,
    attempt_count: 1, external_transmission_id: providerId || null, external_status: text(provider.status, "sandbox_queued"),
    request_hash: requestHash, response_hash: responseHash, completed_at: new Date().toISOString(), created_by: document.created_by,
    metadata: {
      provider: "SUPER PDP", environment: "sandbox", app_environment: "production", sent_to_production: false,
      external_id: externalId, sandbox_party_substitution: true, sandbox_routing: sandbox.routing,
      local_parties: { seller: partyName(object(canonicalPayload.supplier)), buyer: partyName(object(canonicalPayload.customer)) },
    },
  }).select("id").single();
  if (transmissionError) throw Object.assign(new Error("superpdp_transmission_audit_failed"), { status: 502 });
  const { data: exchange, error: exchangeError } = await adminClient.from("superpdp_invoice_exchanges").insert({
    company_id: companyId, document_id: documentId, electronic_invoice_record_id: recordId, connector_id: connector.id,
    transmission_id: transmission.id, provider_invoice_id: providerId || null, external_id: externalId,
    direction: "outgoing", environment: "sandbox", status: text(provider.status, "queued"), xml_format: "cii",
    original_storage_path: pdfPath, pdf_storage_path: pdfPath, xml_storage_path: xmlPath,
    original_sha256: pdfHash, pdf_sha256: pdfHash, xml_sha256: xmlHash,
    canonical_payload: transmittedInvoice, provider_payload: provider, last_synced_at: new Date().toISOString(), created_by: document.created_by,
  }).select("*").single();
  if (exchangeError) throw Object.assign(new Error("superpdp_exchange_audit_failed"), { status: 502 });
  const platformEvent = await adminClient.from("platform_transmission_events").insert({
    company_id: companyId, transmission_id: transmission.id, event_sequence: 1, event_type: "sandbox_invoice_queued",
    status: "succeeded", source: "SUPERPDP", payload_hash: responseHash,
    payload: { environment: "sandbox", provider_invoice_id: providerId || null, external_id: externalId }, created_by: document.created_by,
  });
  if (platformEvent.error) throw Object.assign(new Error("superpdp_transmission_event_audit_failed"), { status: 502 });
  const exchangeEvent = await adminClient.from("superpdp_invoice_events").insert({
    company_id: companyId, exchange_id: exchange.id, provider_event_id: providerId ? `created-${providerId}` : null,
    event_type: "invoice_queued", status: text(provider.status, "queued"), payload_hash: responseHash, payload: provider,
  });
  if (exchangeEvent.error) throw Object.assign(new Error("superpdp_exchange_event_audit_failed"), { status: 502 });
  const artifacts = await adminClient.from("electronic_invoice_artifacts").insert([
    { company_id: companyId, electronic_invoice_record_id: recordId, direction: "outbound", format: "facturx", pdf_storage_path: pdfPath, original_storage_path: pdfPath, artifact_sha256: pdfHash, pdf_sha256: pdfHash, media_type: "application/pdf", status: "validated", created_by: document.created_by, metadata: { provider: "SUPER PDP", environment: "sandbox", external_validation: true } },
    { company_id: companyId, electronic_invoice_record_id: recordId, direction: "outbound", format: "cii", original_storage_path: xmlPath, artifact_sha256: xmlHash, media_type: "application/xml", status: "validated", created_by: document.created_by, metadata: { provider: "SUPER PDP", environment: "sandbox", external_validation: true } },
  ]);
  if (artifacts.error) throw Object.assign(new Error("superpdp_artifact_audit_failed"), { status: 502 });
  await adminClient.from("documents").update({ electronic_invoice_status: "transmitted", electronic_format: "facturx", electronic_profile_code: "EN16931-CII" }).eq("id", documentId);
  return { ok: true, environment: "sandbox", appEnvironment: "production", exchange };
}

async function exchangeXml(userClient: SupabaseClient, adminClient: SupabaseClient, companyId: string, documentId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const { data: exchange, error } = await adminClient.from("superpdp_invoice_exchanges").select("*")
    .eq("company_id", companyId).eq("document_id", documentId).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (error || !exchange?.xml_storage_path) throw Object.assign(new Error("superpdp_xml_unavailable"), { status: 404 });
  const bytes = await downloadStored(adminClient, exchange.xml_storage_path);
  return { ok: true, environment: "sandbox", format: exchange.xml_format || "cii", status: exchange.status, xml: new TextDecoder().decode(bytes), exchangeId: exchange.id };
}

async function syncStatus(userClient: SupabaseClient, adminClient: SupabaseClient, companyId: string, documentId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  await verifiedSandbox(token);
  const { data: exchange, error } = await adminClient.from("superpdp_invoice_exchanges").select("*")
    .eq("company_id", companyId).eq("document_id", documentId).order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (error || !exchange?.provider_invoice_id) throw Object.assign(new Error("superpdp_exchange_not_found"), { status: 404 });
  const result = await superPdpRequest(`/v1.beta/invoices/${encodeURIComponent(exchange.provider_invoice_id)}`, token);
  if (!result.response.ok) throw Object.assign(new Error("superpdp_status_failed"), { status: 502 });
  const provider = object(result.payload), status = text(provider.status, provider.state, exchange.status);
  const update = await adminClient.from("superpdp_invoice_exchanges").update({ status, provider_payload: provider, last_synced_at: new Date().toISOString() }).eq("id", exchange.id);
  if (update.error) throw Object.assign(new Error("superpdp_status_audit_failed"), { status: 502 });
  const digest = await sha256(JSON.stringify(provider));
  const event = await adminClient.from("superpdp_invoice_events").insert({ company_id: companyId, exchange_id: exchange.id, provider_event_id: `sync-${Date.now()}`, event_type: "status_synchronized", status, payload_hash: digest, payload: provider });
  if (event.error) throw Object.assign(new Error("superpdp_exchange_event_audit_failed"), { status: 502 });
  return { ok: true, environment: "sandbox", status, exchangeId: exchange.id };
}

function providerItems(payload: unknown) {
  if (Array.isArray(payload)) return payload.map(object);
  const source = object(payload);
  return array(source.items ?? source.results ?? source.data ?? source.invoices).map(object);
}

const BUYER_LIFECYCLE_STATUSES = new Set([
  "fr:204", // Prise en charge
  "fr:205", // Approuvée
  "fr:206", // Approuvée partiellement
  "fr:207", // En litige
  "fr:208", // Suspendue
  "fr:209", // Traitement terminé
  "fr:210", // Refusée par le destinataire
]);

const BUYER_LIFECYCLE_REASONS: Record<string, Set<string>> = {
  "fr:206": new Set(["AUTRE", "CMD_ERR", "SIRET_ERR", "CODE_ROUTAGE_ERR", "REF_CT_ABSENT", "REF_ERR", "PU_ERR", "REM_ERR", "QTE_ERR", "ART_ERR", "MODPAI_ERR", "QUALITE_ERR", "LIVR_INCOMP"]),
  "fr:207": new Set(["AUTRE", "COORD_BANC_ERR", "TX_TVA_ERR", "MONTANTTOTAL_ERR", "CALCUL_ERR", "NON_CONFORME", "DOUBLON", "DEST_ERR", "TRANSAC_INC", "EMMET_INC", "CONTRAT_TERM", "DOUBLE_FACT", "CMD_ERR", "ADR_ERR", "SIRET_ERR", "CODE_ROUTAGE_ERR", "REF_CT_ABSENT", "REF_ERR", "PU_ERR", "REM_ERR", "QTE_ERR", "ART_ERR", "MODPAI_ERR", "QUALITE_ERR", "LIVR_INCOMP"]),
  "fr:208": new Set(["JUSTIF_ABS", "COORD_BANC_ERR", "CMD_ERR", "SIRET_ERR", "CODE_ROUTAGE_ERR", "REF_CT_ABSENT", "REF_ERR"]),
  "fr:210": new Set(["TX_TVA_ERR", "MONTANTTOTAL_ERR", "CALCUL_ERR", "NON_CONFORME", "DOUBLON", "DEST_ERR", "TRANSAC_INC", "EMMET_INC", "CONTRAT_TERM", "DOUBLE_FACT", "CMD_ERR", "ADR_ERR", "REF_CT_ABSENT"]),
};

function providerEventNote(note: string) {
  return {
    subject: "Décision du destinataire dans PILOZ",
    contents: [{ content: note.slice(0, 1200) }],
  };
}

async function recordProviderEvents(
  adminClient: SupabaseClient,
  companyId: string,
  exchange: JsonObject,
  providerEvents: JsonObject[],
) {
  for (const providerEvent of providerEvents) {
    const providerEventId = text(providerEvent.id);
    if (!providerEventId) continue;
    const payloadHash = await sha256(JSON.stringify(providerEvent));
    const saved = await adminClient.from("superpdp_invoice_events").upsert({
      company_id: companyId,
      exchange_id: exchange.id,
      provider_event_id: providerEventId,
      event_type: "provider_lifecycle_event",
      status: text(providerEvent.status_code, providerEvent.status),
      payload_hash: payloadHash,
      payload: providerEvent,
      occurred_at: text(providerEvent.created_at, new Date().toISOString()),
    }, {
      onConflict: "exchange_id,provider_event_id",
      ignoreDuplicates: true,
    });
    if (saved.error) throw Object.assign(new Error("superpdp_exchange_event_audit_failed"), { status: 502 });
  }
}

async function syncIncomingEvents(
  adminClient: SupabaseClient,
  companyId: string,
  exchange: JsonObject,
  token: string,
) {
  const providerInvoiceId = text(exchange.provider_invoice_id);
  if (!providerInvoiceId) return { count: 0, status: text(exchange.status) };
  const result = await superPdpRequest(
    `/v1.beta/invoice_events?invoice_id=${encodeURIComponent(providerInvoiceId)}&limit=1000`,
    token,
  );
  if (!result.response.ok) {
    console.warn("[PILOZ SUPER PDP] historique entrant indisponible", {
      providerInvoiceId,
      status: result.response.status,
    });
    return { count: 0, status: text(exchange.status) };
  }
  const events = providerItems(result.payload);
  await recordProviderEvents(adminClient, companyId, exchange, events);
  const latest = events[events.length - 1] || {};
  const status = text(latest.status_code, latest.status, exchange.status);
  const updated = await adminClient.from("superpdp_invoice_exchanges").update({
    status,
    last_synced_at: new Date().toISOString(),
  }).eq("id", exchange.id);
  if (updated.error) throw Object.assign(new Error("superpdp_status_audit_failed"), { status: 502 });
  return { count: events.length, status };
}

async function createIncomingLifecycleEvent(
  userClient: SupabaseClient,
  adminClient: SupabaseClient,
  companyId: string,
  documentId: string,
  statusCode: string,
  rawReasonCode: string,
  rawNote: string,
) {
  await requirePurchaseInvoiceReviewer(userClient, companyId);
  if (!BUYER_LIFECYCLE_STATUSES.has(statusCode)) {
    throw Object.assign(new Error("superpdp_lifecycle_status_invalid"), { status: 400 });
  }
  const note = rawNote.trim().replace(/[\u0000-\u001f\u007f]+/g, " ").slice(0, 1200);
  const reasonCode = rawReasonCode.trim().toUpperCase().replace(/[^A-Z0-9_]/g, "").slice(0, 40);
  const allowedReasons = BUYER_LIFECYCLE_REASONS[statusCode];
  if (allowedReasons && !reasonCode) {
    throw Object.assign(new Error("superpdp_lifecycle_reason_required"), { status: 400 });
  }
  if (allowedReasons && !allowedReasons.has(reasonCode)) {
    throw Object.assign(new Error("superpdp_lifecycle_reason_invalid"), { status: 400 });
  }
  if (allowedReasons && !note) {
    throw Object.assign(new Error("superpdp_lifecycle_note_required"), { status: 400 });
  }
  const { data: document, error: documentError } = await adminClient.from("documents")
    .select("id,document_type")
    .eq("company_id", companyId)
    .eq("id", documentId)
    .maybeSingle();
  if (documentError || document?.document_type !== "purchase_invoice") {
    throw Object.assign(new Error("superpdp_purchase_invoice_required"), { status: 404 });
  }
  const { data: exchange, error: exchangeError } = await adminClient.from("superpdp_invoice_exchanges").select("*")
    .eq("company_id", companyId)
    .eq("document_id", documentId)
    .eq("direction", "incoming")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (exchangeError || !exchange?.provider_invoice_id) {
    throw Object.assign(new Error("superpdp_incoming_exchange_required"), { status: 404 });
  }
  const providerInvoiceId = integer(exchange.provider_invoice_id, -1);
  if (providerInvoiceId < 0) {
    throw Object.assign(new Error("superpdp_incoming_exchange_required"), { status: 404 });
  }
  const token = await superPdpToken();
  await verifiedSandbox(token);
  const requestPayload: JsonObject = {
    invoice_id: providerInvoiceId,
    status_code: statusCode,
  };
  if (reasonCode || note) {
    const detail: JsonObject = {};
    if (reasonCode) detail.reason = reasonCode;
    if (note) detail.notes = [providerEventNote(note)];
    requestPayload.details = [detail];
  }
  const result = await superPdpRequest("/v1.beta/invoice_events", token, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(requestPayload),
  });
  if (!result.response.ok) {
    console.error("[PILOZ SUPER PDP] décision destinataire refusée", {
      status: result.response.status,
      providerInvoiceId,
      statusCode,
      providerCode: text(object(result.payload).code, object(result.payload).error),
    });
    throw Object.assign(new Error("superpdp_lifecycle_event_failed"), {
      status: result.response.status >= 400 && result.response.status < 500 ? 409 : 502,
      provider: result.payload,
    });
  }
  const providerEvent = object(result.payload);
  await recordProviderEvents(adminClient, companyId, exchange, [providerEvent]);
  const updated = await adminClient.from("superpdp_invoice_exchanges").update({
    status: text(providerEvent.status_code, statusCode),
    provider_payload: {
      ...object(exchange.provider_payload),
      latest_lifecycle_event: providerEvent,
    },
    last_synced_at: new Date().toISOString(),
  }).eq("id", exchange.id);
  if (updated.error) throw Object.assign(new Error("superpdp_status_audit_failed"), { status: 502 });
  return {
    ok: true,
    environment: "sandbox",
    appEnvironment: "production",
    exchangeId: exchange.id,
    status: text(providerEvent.status_code, statusCode),
    event: providerEvent,
  };
}

function identifierValue(value: unknown) {
  const source = object(value);
  return text(source.value, value);
}

async function providerInvoice(token: string, id: string, format: "en16931" | "cii" | "factur-x") {
  if (format === "en16931") {
    const result = await superPdpRequest(`/v1.beta/invoices/${encodeURIComponent(id)}?format=en16931`, token);
    if (!result.response.ok) throw Object.assign(new Error("superpdp_invoice_download_failed"), { status: 502 });
    const envelope = object(result.payload);
    // The current SUPER PDP API wraps the EN16931 document in `en_invoice`.
    // Keep accepting the former unwrapped payload so existing sandbox fixtures
    // and a future backwards-compatible provider response remain importable.
    const expandedInvoice = object(envelope.en_invoice);
    const payload = Object.keys(expandedInvoice).length ? expandedInvoice : envelope;
    if (!Object.keys(payload).length) throw Object.assign(new Error("superpdp_invoice_download_failed"), { status: 502 });
    return { payload, bytes: new TextEncoder().encode(JSON.stringify(payload)), contentType: "application/json" };
  }
  const result = await superPdpBinary(`/v1.beta/invoices/${encodeURIComponent(id)}?format=${format}`, token, format === "factur-x" ? "application/pdf" : "application/xml");
  return { payload: {}, ...result };
}

async function importIncomingInvoice(adminClient: SupabaseClient, companyId: string, connector: JsonObject, token: string, summary: JsonObject) {
  const providerId = text(summary.id, summary.invoice_id, summary.uuid);
  if (!providerId) return { skipped: true, reason: "missing_provider_id" };
  const existing = await adminClient.from("superpdp_invoice_exchanges").select("*")
    .eq("company_id", companyId).eq("direction", "incoming").eq("provider_invoice_id", providerId).maybeSingle();
  if (existing.data) {
    const lifecycle = await syncIncomingEvents(adminClient, companyId, existing.data, token);
    return { skipped: true, idempotent: true, documentId: existing.data.document_id, lifecycle };
  }
  const [canonical, cii, facturx] = await Promise.all([
    providerInvoice(token, providerId, "en16931"), providerInvoice(token, providerId, "cii"), providerInvoice(token, providerId, "factur-x"),
  ]);
  const invoice = canonical.payload, seller = object(invoice.seller), totals = object(invoice.totals);
  const legalRegistration = identifierValue(seller.legal_registration_identifier);
  let supplierQuery = adminClient.from("suppliers").select("*").eq("company_id", companyId);
  supplierQuery = legalRegistration ? supplierQuery.eq("siret", legalRegistration) : supplierQuery.eq("legal_name", partyName(seller));
  let { data: supplier } = await supplierQuery.limit(1).maybeSingle();
  if (!supplier) {
    const address = object(seller.postal_address);
    const created = await adminClient.from("suppliers").insert({
      company_id: companyId, legal_name: partyName(seller) || "Fournisseur SUPER PDP", siret: legalRegistration || null,
      vat_number: text(seller.vat_identifier) || null, email: text(object(seller.electronic_address).value) || null,
      address_line_1: text(address.address_line1) || null, address_line_2: text(address.address_line2) || null,
      postal_code: text(address.post_code) || null, city: text(address.city) || null, country_code: text(address.country_code, "FR"), active: true,
    }).select("*").single();
    if (created.error) throw Object.assign(new Error("superpdp_supplier_import_failed"), { status: 502 });
    supplier = created.data;
  }
  const sourceLines = array(invoice.lines).map(object);
  const totalVat = object(totals.total_vat_amount);
  const totalWithoutTax = Number(totals.total_without_vat || 0), totalTax = Number(totalVat.value ?? totalVat.amount ?? 0), totalWithTax = Number(totals.total_with_vat || 0);
  const documentInsert = await adminClient.from("documents").insert({
    company_id: companyId, document_type: "purchase_invoice", supplier_id: supplier.id, status: "pending",
    issue_date: text(invoice.issue_date, new Date().toISOString().slice(0, 10)), due_date: text(invoice.payment_due_date) || null,
    client_reference: text(invoice.number), currency: text(invoice.currency_code, "EUR"), subject: `Facture fournisseur ${text(invoice.number)}`,
    total_cost: totalWithoutTax, total_excl_tax: totalWithoutTax, total_tax: totalTax, total_incl_tax: totalWithTax,
    metadata: { superpdp: { environment: "sandbox", provider_invoice_id: providerId, imported_at: new Date().toISOString() }, electronic_source: "superpdp_sandbox" },
  }).select("*").single();
  if (documentInsert.error) throw Object.assign(new Error("superpdp_purchase_invoice_import_failed"), { status: 502 });
  const document = documentInsert.data;
  if (sourceLines.length) {
    const lineRows = sourceLines.map((line, index) => {
      const price = object(line.price_details), item = object(line.item_information), vat = object(line.vat_information);
      const net = Number(line.net_amount || 0), rate = Number(vat.invoiced_item_vat_rate || 0), quantity = Number(line.invoiced_quantity || 1) || 1;
      return { company_id: companyId, document_id: document.id, position: index + 1, line_type: "item", reference: text(item.seller_identifier) || null,
        name: text(item.name, `Ligne ${index + 1}`), description: text(item.description) || null, quantity,
        unit: text(line.invoiced_quantity_code, "unité"), unit_cost_snapshot: Number(price.item_net_price || (net / quantity) || 0),
        unit_price: Number(price.item_net_price || (net / quantity) || 0), discount_rate: 0, tax_rate: rate,
        total_excl_tax: net, total_tax: net * rate / 100, total_incl_tax: net * (1 + rate / 100),
        line_metadata: { electronic_source: "superpdp_sandbox", provider_line_id: text(line.identifier) } };
    });
    const inserted = await adminClient.from("document_lines").insert(lineRows);
    if (inserted.error) throw Object.assign(new Error("superpdp_purchase_invoice_lines_import_failed"), { status: 502 });
  }
  const base = `${companyId}/electronic-invoices/sandbox/incoming/${providerId}/${document.id}`;
  const pdfPath = await storageUpload(adminClient, `${base}.factur-x.pdf`, facturx.bytes, "application/pdf");
  const xmlPath = await storageUpload(adminClient, `${base}.cii.xml`, cii.bytes, "application/xml");
  const [pdfHash, xmlHash, canonicalHash] = await Promise.all([sha256(facturx.bytes), sha256(cii.bytes), sha256(JSON.stringify(invoice))]);
  const externalId = text(summary.external_id, `SUPERPDP-${providerId}`).slice(0, 120);
  const exchangeInsert = await adminClient.from("superpdp_invoice_exchanges").insert({
    company_id: companyId, document_id: document.id, connector_id: connector.id, provider_invoice_id: providerId,
    external_id: externalId, direction: "incoming", environment: "sandbox", status: text(summary.status, "received"), xml_format: "cii",
    original_storage_path: pdfPath, pdf_storage_path: pdfPath, xml_storage_path: xmlPath, original_sha256: pdfHash, pdf_sha256: pdfHash,
    xml_sha256: xmlHash, canonical_payload: invoice, provider_payload: summary, last_synced_at: new Date().toISOString(),
  }).select("*").single();
  if (exchangeInsert.error) throw Object.assign(new Error("superpdp_exchange_audit_failed"), { status: 502 });
  const eventInsert = await adminClient.from("superpdp_invoice_events").insert({ company_id: companyId, exchange_id: exchangeInsert.data.id,
    provider_event_id: `received-${providerId}`, event_type: "invoice_received", status: text(summary.status, "received"), payload_hash: canonicalHash, payload: summary });
  if (eventInsert.error) throw Object.assign(new Error("superpdp_exchange_event_audit_failed"), { status: 502 });
  await syncIncomingEvents(adminClient, companyId, exchangeInsert.data, token);
  return { imported: true, documentId: document.id, exchangeId: exchangeInsert.data.id, providerInvoiceId: providerId };
}

async function syncIncoming(userClient: SupabaseClient, adminClient: SupabaseClient, companyId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  await verifiedSandbox(token);
  const connector = await connectorFor(adminClient, companyId);
  // SUPER PDP exposes the wire values `in` and `out` for this filter.
  // `incoming` remains the internal value stored in PILOZ's audit tables.
  const list = await superPdpRequest("/v1.beta/invoices?direction=in&limit=100", token);
  if (!list.response.ok) {
    console.error("[PILOZ SUPER PDP] liste des factures entrantes refusée", {
      status: list.response.status,
      providerCode: text(object(list.payload).code, object(list.payload).error),
    });
    throw Object.assign(new Error("superpdp_incoming_list_failed"), { status: 502 });
  }
  const results = [];
  for (const item of providerItems(list.payload)) {
    try { results.push(await importIncomingInvoice(adminClient, companyId, connector, token, item)); }
    catch (error) {
      console.error("[PILOZ SUPER PDP] import entrant impossible", { providerInvoiceId: text(item.id), code: (error as Error).message });
      results.push({ imported: false, providerInvoiceId: text(item.id), error: (error as Error).message });
    }
  }
  return {
    ok: true,
    environment: "sandbox",
    appEnvironment: "production",
    found: providerItems(list.payload).length,
    imported: results.filter(item => object(item).imported).length,
    failed: results.filter(item => object(item).imported === false).length,
    results,
  };
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !serviceRole) return json({ error: "Connecteur non configuré." }, 503);
  const userClient = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false, autoRefreshToken: false } });
  const adminClient = createClient(url, serviceRole, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide." }, 401);
  let body: RequestBody;
  try { const raw = await req.text(); body = raw ? JSON.parse(raw) : {}; }
  catch { return json({ error: "Demande invalide." }, 400); }

  try {
    const action = text(body.action), companyId = safeUuid(body.companyId), documentId = safeUuid(body.documentId);
    const companyActions = new Set(["superpdp_test", "superpdp_send_test_invoice", "superpdp_send_document", "superpdp_document_xml", "superpdp_sync_status", "superpdp_sync_incoming", "superpdp_create_invoice_event"]);
    if (companyActions.has(action) && !companyId) return json({ error: "Entreprise invalide.", code: "invalid_company_id" }, 400);
    if (["superpdp_send_document", "superpdp_document_xml", "superpdp_sync_status", "superpdp_create_invoice_event"].includes(action) && !documentId) {
      return json({ error: "Document invalide.", code: "invalid_document_id" }, 400);
    }
    if (action === "superpdp_test") return json(await testSuperPdp(userClient, companyId));
    if (action === "superpdp_send_test_invoice") return json(await sendSuperPdpTestInvoice(userClient, companyId, text(body.confirmation)));
    if (action === "superpdp_send_document") return json(await sendDocument(userClient, adminClient, companyId, documentId));
    if (action === "superpdp_document_xml") return json(await exchangeXml(userClient, adminClient, companyId, documentId));
    if (action === "superpdp_sync_status") return json(await syncStatus(userClient, adminClient, companyId, documentId));
    if (action === "superpdp_sync_incoming") return json(await syncIncoming(userClient, adminClient, companyId));
    if (action === "superpdp_create_invoice_event") {
      return json(await createIncomingLifecycleEvent(
        userClient,
        adminClient,
        companyId,
        documentId,
        text(body.statusCode),
        text(body.reasonCode),
        text(body.note),
      ));
    }
    if (action === "configure_sandbox" && companyId) {
      const { data, error } = await userClient.rpc("create_platform_sandbox", { target_company_id: companyId });
      if (error) return json({ error: "Le bac à sable n'a pas pu être configuré." }, 403);
      return json({ connectorId: data, displayStatus: "Simulation", simulation: true, production: false });
    }
    if (action === "simulate" && body.recordId && body.idempotencyKey) {
      const { data, error } = await userClient.rpc("run_platform_sandbox_simulation", { target_record_id: body.recordId, target_operation: body.operation || "send_invoice", target_idempotency_key: body.idempotencyKey });
      if (error) return json({ error: "La simulation n'a pas abouti.", code: error.code || "simulation_failed" }, 409);
      return json(data);
    }
    if (action === "production") return json({ error: "Le connecteur SUPER PDP est volontairement verrouillé sur le bac à sable.", code: "superpdp_sandbox_required" }, 503);
    return json({ error: "Action de connecteur inconnue." }, 400);
  } catch (error) {
    const code = String((error as Error)?.message || "platform_connector_failed");
    const status = Math.max(400, Math.min(599, Number((error as { status?: number })?.status || 502)));
    console.error("[PILOZ platform connector] request failed", { code, status });
    const messages: Record<string, string> = {
      forbidden_purchase_invoice_review: "Votre rôle ne permet pas de traiter les factures fournisseurs.",
      superpdp_lifecycle_status_invalid: "Cette décision n’est pas reconnue par le circuit de facturation électronique.",
      superpdp_lifecycle_reason_required: "Choisissez le type de motif avant de transmettre cette décision.",
      superpdp_lifecycle_reason_invalid: "Ce motif n’est pas autorisé pour la décision sélectionnée.",
      superpdp_lifecycle_note_required: "Expliquez la décision avant de la transmettre au fournisseur.",
      superpdp_purchase_invoice_required: "Cette action est réservée aux factures fournisseurs.",
      superpdp_incoming_exchange_required: "Cette facture ne provient pas de la boîte de réception SUPER PDP.",
      superpdp_lifecycle_event_failed: "SUPER PDP n’a pas accepté cette décision. La facture n’a pas changé de statut.",
      superpdp_status_audit_failed: "La décision a été transmise, mais son statut n’a pas pu être enregistré dans PILOZ.",
      forbidden: "Vous n’avez pas l’autorisation de gérer la facturation électronique.",
      superpdp_credentials_not_configured: "Les identifiants serveur SUPER PDP ne sont pas encore configurés.",
      superpdp_authentication_failed: "SUPER PDP a refusé les identifiants de l’application sandbox.",
      superpdp_account_is_not_sandbox: "L’application SUPER PDP configurée n’appartient pas au bac à sable.",
      superpdp_sandbox_required: "Le connecteur SUPER PDP est verrouillé sur le bac à sable.",
      superpdp_test_confirmation_required: "Confirmez explicitement l’envoi de la facture de test.",
      superpdp_connector_not_configured: "Testez d’abord la connexion SUPER PDP dans les paramètres.",
      finalized_fiscal_document_required: "Finalisez la facture avant de la transmettre.",
      final_pdf_unavailable: "Le PDF définitif n’est pas encore disponible. Réessayez dans quelques instants.",
      canonical_invoice_invalid: "La facture ne contient pas toutes les données requises pour la facturation électronique.",
      superpdp_seller_electronic_address_required: "L’identifiant électronique de votre entreprise est manquant.",
      superpdp_buyer_electronic_address_required: "L’identifiant électronique du client est manquant.",
      superpdp_invoice_lines_required: "La facture doit contenir au moins une ligne facturable.",
      superpdp_invoice_conversion_failed: "SUPER PDP n’a pas pu convertir cette facture en Factur-X et CII. Vérifiez les montants, la TVA et les coordonnées des deux entreprises.",
      superpdp_sandbox_routing_failed: "SUPER PDP n’a pas fourni les entreprises de test nécessaires au routage dans le bac à sable.",
      superpdp_xml_unavailable: "Aucun XML électronique n’est encore disponible pour ce document.",
      superpdp_invoice_send_failed: "SUPER PDP a refusé cette facture dans le bac à sable.",
      superpdp_artifact_storage_failed: "Les fichiers Factur-X et CII ont été créés, mais Piloz n’a pas pu les archiver.",
      superpdp_transmission_audit_failed: "L’envoi a abouti, mais son journal de transmission n’a pas pu être enregistré.",
      superpdp_exchange_audit_failed: "L’échange SUPER PDP n’a pas pu être enregistré dans Piloz.",
      superpdp_transmission_event_audit_failed: "L’évènement de transmission SUPER PDP n’a pas pu être enregistré.",
      superpdp_exchange_event_audit_failed: "L’évènement d’échange SUPER PDP n’a pas pu être enregistré.",
      superpdp_artifact_audit_failed: "Les justificatifs électroniques n’ont pas pu être inscrits dans le registre Piloz.",
      superpdp_incoming_list_failed: "SUPER PDP n’a pas pu fournir la liste des factures reçues. Vérifiez que l’entreprise sandbox est bien validée, puis réessayez.",
    };
    const provider = object((error as { provider?: unknown })?.provider);
    const providerMessage = text(provider.message).replace(/[\r\n\t]+/g, " ").slice(0, 240);
    const baseMessage = messages[code] || "L’opération SUPER PDP n’a pas pu aboutir.";
    return json({ error: providerMessage ? `${baseMessage} Détail SUPER PDP : ${providerMessage}` : baseMessage, code }, status);
  }
});
