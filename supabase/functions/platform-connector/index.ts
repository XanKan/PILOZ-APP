import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

type RequestBody = {
  action?: string;
  companyId?: string;
  recordId?: string;
  operation?: string;
  idempotencyKey?: string;
  confirmation?: string;
};

const SUPERPDP_API_URL = "https://api.superpdp.tech";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function safeUuid(value: unknown) {
  const normalized = String(value || "").trim();
  return UUID.test(normalized) ? normalized : "";
}

async function responsePayload(response: Response) {
  if (response.status === 204 || response.status === 205) return null;
  const text = await response.text();
  if (!text.trim()) return null;
  const contentType = (response.headers.get("content-type") || "").toLowerCase();
  if (!contentType.includes("json")) return { text, contentType };
  try { return JSON.parse(text); }
  catch { throw Object.assign(new Error("superpdp_invalid_json_response"), { status: 502 }); }
}

async function superPdpToken() {
  const clientId = Deno.env.get("SUPERPDP_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("SUPERPDP_CLIENT_SECRET") || "";
  const environment = (Deno.env.get("SUPERPDP_ENVIRONMENT") || "sandbox").toLowerCase();
  if (!clientId || !clientSecret) throw Object.assign(new Error("superpdp_credentials_not_configured"), { status: 503 });
  if (environment !== "sandbox") throw Object.assign(new Error("superpdp_sandbox_required"), { status: 503 });
  const basic = btoa(`${clientId}:${clientSecret}`);
  let response = await fetch(`${SUPERPDP_API_URL}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json", Authorization: `Basic ${basic}` },
    body: new URLSearchParams({ grant_type: "client_credentials" }),
  });
  let payload = await responsePayload(response) as Record<string, unknown> | null;
  // Some OAuth servers accept confidential clients in the form body instead
  // of HTTP Basic. The fallback remains server-side and never exposes either
  // credential to the browser.
  if (!response.ok || !payload?.access_token) {
    response = await fetch(`${SUPERPDP_API_URL}/oauth2/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: clientSecret }),
    });
    payload = await responsePayload(response) as Record<string, unknown> | null;
  }
  if (!response.ok || !payload?.access_token) {
    throw Object.assign(new Error("superpdp_authentication_failed"), { status: response.status === 401 ? 401 : 502 });
  }
  return String(payload.access_token);
}

async function superPdpRequest(path: string, accessToken: string, init: RequestInit = {}) {
  const response = await fetch(`${SUPERPDP_API_URL}${path}`, {
    ...init,
    headers: { Accept: "application/json", Authorization: `Bearer ${accessToken}`, ...(init.headers || {}) },
  });
  return { response, payload: await responsePayload(response) };
}

async function requireElectronicInvoiceManager(userClient: SupabaseClient, companyId: string) {
  const { data, error } = await userClient.rpc("has_company_permission", {
    target_company_id: companyId,
    target_permission: "electronic_invoice_manage",
  });
  if (error || data !== true) throw Object.assign(new Error("forbidden"), { status: 403 });
}

function safeCompany(value: unknown) {
  const company = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return {
    id: Number(company.id) || null,
    environment: String(company.env || ""),
    numberScheme: String(company.number_scheme || ""),
    number: String(company.number || ""),
    formalName: String(company.formal_name || ""),
    tradeName: String(company.trade_name || ""),
    city: String(company.city || ""),
    country: String(company.country || ""),
  };
}

async function testSuperPdp(userClient: SupabaseClient, companyId: string) {
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  const { response, payload } = await superPdpRequest("/v1.beta/companies/me", token);
  if (!response.ok) throw Object.assign(new Error("superpdp_company_check_failed"), { status: 502 });
  const company = safeCompany(payload);
  if (company.environment !== "sandbox") throw Object.assign(new Error("superpdp_account_is_not_sandbox"), { status: 409 });
  const { data: connectorId, error } = await userClient.rpc("configure_superpdp_sandbox_connector", {
    target_company_id: companyId,
    target_external_company: payload,
  });
  if (error) throw Object.assign(new Error("superpdp_connector_registration_failed"), { status: 409 });
  return { ok: true, connectorId, provider: "SUPER PDP", environment: "sandbox", company };
}

async function sendSuperPdpTestInvoice(userClient: SupabaseClient, companyId: string, confirmation: string) {
  if (confirmation !== "SEND_SUPERPDP_SANDBOX_TEST") throw Object.assign(new Error("superpdp_test_confirmation_required"), { status: 400 });
  await requireElectronicInvoiceManager(userClient, companyId);
  const token = await superPdpToken();
  const companyCheck = await superPdpRequest("/v1.beta/companies/me", token);
  if (!companyCheck.response.ok || safeCompany(companyCheck.payload).environment !== "sandbox") {
    throw Object.assign(new Error("superpdp_sandbox_required"), { status: 409 });
  }
  const generated = await fetch(`${SUPERPDP_API_URL}/v1.beta/invoices/generate_test_invoice?format=factur-x`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/pdf" },
  });
  const generatedType = generated.headers.get("content-type") || "";
  const invoice = new Uint8Array(await generated.arrayBuffer());
  if (!generated.ok || !generatedType.toLowerCase().includes("pdf") || !invoice.length) {
    throw Object.assign(new Error("superpdp_test_invoice_generation_failed"), { status: 502 });
  }
  const externalId = `PILOZ-TEST-${crypto.randomUUID().slice(0, 24)}`.slice(0, 36);
  const sent = await superPdpRequest(`/v1.beta/invoices?external_id=${encodeURIComponent(externalId)}`, token, {
    method: "POST",
    headers: { "Content-Type": "application/pdf" },
    body: invoice,
  });
  if (!sent.response.ok) throw Object.assign(new Error("superpdp_test_invoice_send_failed"), { status: 502 });
  const result = sent.payload && typeof sent.payload === "object" ? sent.payload as Record<string, unknown> : {};
  const { data: transmissionId, error: auditError } = await userClient.rpc("record_superpdp_sandbox_test_transmission", {
    target_company_id: companyId,
    target_external_id: externalId,
    target_external_invoice_id: result.id == null ? "" : String(result.id),
  });
  if (auditError) throw Object.assign(new Error("superpdp_test_audit_failed"), { status: 409 });
  return {
    ok: true,
    provider: "SUPER PDP",
    environment: "sandbox",
    externalId,
    invoiceId: Number(result.id) || null,
    transmissionId,
    direction: String(result.direction || "outgoing"),
    createdAt: String(result.created_at || ""),
  };
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return json({ error: "Connecteur non configuré." }, 503);
  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide." }, 401);
  let body: RequestBody;
  try { const raw = await req.text(); body = raw ? JSON.parse(raw) : {}; }
  catch { return json({ error: "Demande invalide." }, 400); }

  try {
    const companyId = safeUuid(body.companyId);
    if (["superpdp_test", "superpdp_send_test_invoice"].includes(String(body.action)) && !companyId) {
      return json({ error: "Entreprise invalide.", code: "invalid_company_id" }, 400);
    }
    if (body.action === "superpdp_test") return json(await testSuperPdp(userClient, companyId));
    if (body.action === "superpdp_send_test_invoice") {
      return json(await sendSuperPdpTestInvoice(userClient, companyId, String(body.confirmation || "")));
    }
    if (body.action === "configure_sandbox" && companyId) {
      const { data, error } = await userClient.rpc("create_platform_sandbox", { target_company_id: companyId });
      if (error) return json({ error: "Le sandbox n'a pas pu être configuré." }, 403);
      return json({ connectorId: data, displayStatus: "Simulation", simulation: true, production: false });
    }
    if (body.action === "simulate" && body.recordId && body.idempotencyKey) {
      const { data, error } = await userClient.rpc("run_platform_sandbox_simulation", {
        target_record_id: body.recordId,
        target_operation: body.operation || "send_invoice",
        target_idempotency_key: body.idempotencyKey,
      });
      if (error) return json({ error: "La simulation n'a pas abouti.", code: error.code || "simulation_failed" }, 409);
      return json(data);
    }
    if (body.action === "production") {
      return json({ error: "Aucune plateforme agréée de production n'est configurée et validée.", code: "production_connector_not_configured" }, 503);
    }
    return json({ error: "Action de connecteur inconnue." }, 400);
  } catch (error) {
    const code = String((error as Error)?.message || "platform_connector_failed");
    const status = Math.max(400, Math.min(599, Number((error as { status?: number })?.status || 502)));
    console.error("[PILOZ platform connector] request failed", { code, status });
    const messages: Record<string, string> = {
      forbidden: "Vous n’avez pas l’autorisation de configurer la facturation électronique.",
      superpdp_credentials_not_configured: "Les identifiants serveur Super PDP ne sont pas encore configurés.",
      superpdp_authentication_failed: "Super PDP a refusé les identifiants de l’application sandbox.",
      superpdp_account_is_not_sandbox: "L’application Super PDP configurée n’appartient pas au bac à sable.",
      superpdp_sandbox_required: "Le connecteur est verrouillé sur le bac à sable pour ce test.",
      superpdp_test_confirmation_required: "Confirmez explicitement l’envoi de la facture de test.",
    };
    return json({ error: messages[code] || "La connexion à Super PDP n’a pas pu terminer cette opération.", code }, status);
  }
});
