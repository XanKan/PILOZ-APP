import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

type JsonObject = Record<string, unknown>;
const API_URL = (Deno.env.get("SUPERPDP_API_URL") || "https://api.superpdp.tech").replace(/\/$/, "");
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}
function text(...values: unknown[]) {
  for (const value of values) {
    const candidate = String(value ?? "").trim();
    if (candidate) return candidate;
  }
  return "";
}
function safeUuid(value: unknown) {
  const valueText = text(value);
  return UUID.test(valueText) ? valueText : "";
}
function base64Url(bytes: Uint8Array) {
  let binary = "";
  bytes.forEach(byte => binary += String.fromCharCode(byte));
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function fromBase64Url(value: string) {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(normalized);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}
function randomUrlSafe(size = 32) {
  return base64Url(crypto.getRandomValues(new Uint8Array(size)));
}
async function sha256Bytes(value: string) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}
async function sha256(value: string) {
  return Array.from(await sha256Bytes(value)).map(byte => byte.toString(16).padStart(2, "0")).join("");
}
async function encryptionKey() {
  const secret = Deno.env.get("SUPERPDP_TOKEN_ENCRYPTION_KEY") || "";
  if (secret.length < 32) throw Object.assign(new Error("token_encryption_key_missing"), { status: 503 });
  return crypto.subtle.importKey("raw", await sha256Bytes(secret), "AES-GCM", false, ["encrypt", "decrypt"]);
}
async function encrypt(value: string) {
  if (!value) return null;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await encryptionKey(), new TextEncoder().encode(value)));
  return `v1.${base64Url(iv)}.${base64Url(encrypted)}`;
}
async function decrypt(value: unknown) {
  const [version, rawIv, rawCipher] = text(value).split(".");
  if (version !== "v1" || !rawIv || !rawCipher) throw Object.assign(new Error("encrypted_token_invalid"), { status: 500 });
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64Url(rawIv) }, await encryptionKey(), fromBase64Url(rawCipher));
  return new TextDecoder().decode(clear);
}
async function responsePayload(response: Response) {
  if (response.status === 204 || response.status === 205) return null;
  const raw = await response.text();
  if (!raw.trim()) return null;
  try { return JSON.parse(raw); } catch { return { text: raw.slice(0, 500) }; }
}
async function providerRequest(path: string, token: string, init: RequestInit = {}) {
  const response = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: { Accept: "application/json", Authorization: `Bearer ${token}`, ...(init.headers || {}) },
  });
  return { response, payload: await responsePayload(response) };
}
function oauthConfiguration() {
  const clientId = Deno.env.get("SUPERPDP_PRODUCTION_CLIENT_ID") || "";
  const clientSecret = Deno.env.get("SUPERPDP_PRODUCTION_CLIENT_SECRET") || "";
  const supabaseUrl = (Deno.env.get("SUPABASE_URL") || "").replace(/\/$/, "");
  const redirectUri = Deno.env.get("SUPERPDP_REDIRECT_URI") || `${supabaseUrl}/functions/v1/superpdp-oauth/callback`;
  if (!clientId || !clientSecret || !redirectUri) throw Object.assign(new Error("production_credentials_missing"), { status: 503 });
  return { clientId, clientSecret, redirectUri };
}
async function exchangeToken(values: Record<string, string>) {
  const { clientId, clientSecret } = oauthConfiguration();
  const request = async (basic: boolean) => {
    const headers: Record<string, string> = { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" };
    const parameters = { ...values };
    if (basic) headers.Authorization = `Basic ${btoa(`${clientId}:${clientSecret}`)}`;
    else Object.assign(parameters, { client_id: clientId, client_secret: clientSecret });
    const response = await fetch(`${API_URL}/oauth2/token`, { method: "POST", headers, body: new URLSearchParams(parameters) });
    return { response, payload: object(await responsePayload(response)) };
  };
  let result = await request(true);
  if (!result.response.ok || !result.payload.access_token) result = await request(false);
  if (!result.response.ok || !result.payload.access_token) {
    console.error("[PILOZ SUPER PDP OAuth] token exchange refused", { status: result.response.status, code: text(result.payload.error) });
    throw Object.assign(new Error("token_exchange_failed"), { status: 502 });
  }
  return result.payload;
}
async function requireManager(userClient: SupabaseClient, companyId: string) {
  const { data, error } = await userClient.rpc("has_company_permission", {
    target_company_id: companyId,
    target_permission: "electronic_invoice_manage",
  });
  if (error || data !== true) throw Object.assign(new Error("forbidden"), { status: 403 });
}
async function authorizationFor(adminClient: SupabaseClient, companyId: string) {
  const { data, error } = await adminClient.from("superpdp_company_authorizations").select("*")
    .eq("company_id", companyId).is("revoked_at", null).maybeSingle();
  if (error || !data) throw Object.assign(new Error("authorization_missing"), { status: 409 });
  return data as JsonObject;
}
async function validAccessToken(adminClient: SupabaseClient, authorization: JsonObject) {
  const expiresAt = Date.parse(text(authorization.access_token_expires_at));
  if (!expiresAt || expiresAt > Date.now() + 120_000) return decrypt(authorization.access_token_ciphertext);
  const refreshToken = authorization.refresh_token_ciphertext ? await decrypt(authorization.refresh_token_ciphertext) : "";
  if (!refreshToken) throw Object.assign(new Error("reauthorization_required"), { status: 401 });
  const token = await exchangeToken({ grant_type: "refresh_token", refresh_token: refreshToken });
  const accessToken = text(token.access_token), replacementRefresh = text(token.refresh_token, refreshToken);
  const expiresIn = Math.max(60, Number(token.expires_in) || 3600);
  const { error } = await adminClient.from("superpdp_company_authorizations").update({
    access_token_ciphertext: await encrypt(accessToken),
    refresh_token_ciphertext: await encrypt(replacementRefresh),
    token_type: text(token.token_type, authorization.token_type),
    granted_scope: text(token.scope, authorization.granted_scope),
    access_token_expires_at: new Date(Date.now() + expiresIn * 1000).toISOString(),
    last_token_refresh_at: new Date().toISOString(),
    last_error_code: null,
  }).eq("id", authorization.id);
  if (error) throw Object.assign(new Error("token_refresh_storage_failed"), { status: 502 });
  await adminClient.from("superpdp_consent_events").insert({ company_id: authorization.company_id, authorization_id: authorization.id, event_type: "token_refreshed", evidence: { provider: "SUPER PDP" } });
  return accessToken;
}
function connectionState(session: JsonObject) {
  const companyVerification = text(session.company_verification_status, "needs_review");
  const identityVerification = text(session.user_identity_verification_status);
  const active = companyVerification === "verified" && (!identityVerification || identityVerification === "verified");
  return { companyVerification, identityVerification, active };
}
async function refreshVerification(adminClient: SupabaseClient, companyId: string, actorId?: string) {
  const authorization = await authorizationFor(adminClient, companyId);
  const token = await validAccessToken(adminClient, authorization);
  const [sessionResult, companyResult, directoryResult] = await Promise.all([
    providerRequest("/v1.beta/oauth2_sessions/me", token),
    providerRequest("/v1.beta/companies/me", token),
    providerRequest("/v1.beta/directory_entries?limit=100", token),
  ]);
  if (!sessionResult.response.ok || !companyResult.response.ok) throw Object.assign(new Error("provider_verification_failed"), { status: 502 });
  const session = object(sessionResult.payload), company = object(companyResult.payload), connection = connectionState(session);
  const directoryPayload = object(directoryResult.payload);
  const entries = Array.isArray(directoryResult.payload)
    ? directoryResult.payload
    : Array.isArray(directoryPayload.data)
      ? directoryPayload.data as unknown[]
      : Array.isArray(directoryPayload.items)
        ? directoryPayload.items as unknown[]
        : [];
  const activeEntry = entries.map(object).find(entry => text(entry.directory) === "ppf" && ["created", "active", "ok", "enabled"].includes(text(entry.status).toLowerCase()));
  const connectorStatus = connection.active ? "active" : "validation_required";
  const now = new Date().toISOString();
  const { error: updateError } = await adminClient.from("superpdp_company_authorizations").update({
    provider_company_id: company.id == null ? null : String(company.id),
    provider_company_number: text(company.number),
    provider_company_name: text(company.trade_name, company.formal_name),
    company_verification_status: connection.companyVerification,
    user_identity_verification_status: connection.identityVerification || null,
    directory_status: activeEntry ? "active" : text(authorization.directory_status, "not_requested"),
    directory_entry_id: activeEntry?.id == null ? authorization.directory_entry_id : String(activeEntry.id),
    last_verified_at: now,
    last_error_code: null,
  }).eq("id", authorization.id);
  if (updateError) throw Object.assign(new Error("verification_storage_failed"), { status: 502 });
  const { error: connectorError } = await adminClient.from("platform_connectors").update({
    status: connectorStatus,
    production_enabled: connection.active,
    credential_secret_ref: `superpdp_company_authorizations:${authorization.id}`,
    non_secret_configuration: {
      external_company_id: company.id == null ? null : String(company.id),
      external_company_number: text(company.number),
      external_company_name: text(company.trade_name, company.formal_name),
      verification_status: connection.companyVerification,
      verified_at: now,
    },
  }).eq("id", authorization.connector_id);
  if (connectorError) throw Object.assign(new Error("connector_storage_failed"), { status: 502 });
  await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, authorization_id: authorization.id, actor_id: actorId || null, event_type: "verification_refreshed", evidence: { company_verification_status: connection.companyVerification, user_identity_verification_status: connection.identityVerification } });
  return { ok: true, status: connectorStatus, productionEnabled: connection.active, companyVerificationStatus: connection.companyVerification, userIdentityVerificationStatus: connection.identityVerification, directoryStatus: activeEntry ? "active" : text(authorization.directory_status, "not_requested") };
}
async function startAuthorization(userClient: SupabaseClient, adminClient: SupabaseClient, user: { id: string; email?: string }, companyId: string) {
  await requireManager(userClient, companyId);
  const { data: company, error } = await adminClient.from("company_settings").select("siren,siret,email,legal_name,trade_name").eq("company_id", companyId).maybeSingle();
  if (error || !company) throw Object.assign(new Error("company_settings_missing"), { status: 409 });
  const siren = text(company.siren, String(company.siret || "").replace(/\D/g, "").slice(0, 9)).replace(/\D/g, "");
  if (siren.length !== 9) throw Object.assign(new Error("company_siren_required"), { status: 409 });
  const state = randomUrlSafe(32), verifier = randomUrlSafe(64), challenge = base64Url(await sha256Bytes(verifier));
  const { error: stateError } = await adminClient.from("superpdp_oauth_states").insert({
    state_hash: await sha256(state), company_id: companyId, user_id: user.id,
    pkce_verifier_ciphertext: await encrypt(verifier), expires_at: new Date(Date.now() + 10 * 60_000).toISOString(),
  });
  if (stateError) throw Object.assign(new Error("oauth_state_storage_failed"), { status: 502 });
  await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, actor_id: user.id, event_type: "authorization_started", evidence: { provider: "SUPER PDP", company_number_scheme: "fr_siren" } });
  const configuration = oauthConfiguration();
  const query = new URLSearchParams({
    response_type: "code", client_id: configuration.clientId, redirect_uri: configuration.redirectUri,
    state, code_challenge: challenge, code_challenge_method: "S256",
    login_hint: text(user.email, company.email), superpdp_company_number: siren,
    superpdp_company_number_scheme: "fr_siren",
  });
  return { ok: true, url: `${API_URL}/oauth2/authorize?${query}`, expiresIn: 600 };
}
function appRedirect(status: string, code = "") {
  const base = (Deno.env.get("PILOZ_APP_URL") || "https://app.piloz.fr").replace(/\/$/, "");
  const query = new URLSearchParams({ superpdp: status });
  if (code) query.set("code", code);
  return `${base}/#settings/einvoicing?${query}`;
}
async function oauthCallback(req: Request, adminClient: SupabaseClient) {
  const url = new URL(req.url), state = text(url.searchParams.get("state")), code = text(url.searchParams.get("code"));
  if (url.searchParams.get("error")) return Response.redirect(appRedirect("error", text(url.searchParams.get("error"))), 303);
  if (!state || !code) return Response.redirect(appRedirect("error", "oauth_callback_invalid"), 303);
  const { data: stored, error } = await adminClient.from("superpdp_oauth_states").select("*").eq("state_hash", await sha256(state)).maybeSingle();
  if (error || !stored || stored.consumed_at || Date.parse(stored.expires_at) <= Date.now()) return Response.redirect(appRedirect("error", "oauth_state_invalid"), 303);
  const { data: claimedState, error: claimError } = await adminClient.from("superpdp_oauth_states")
    .update({ consumed_at: new Date().toISOString() }).eq("id", stored.id).is("consumed_at", null)
    .select("id").maybeSingle();
  if (claimError || !claimedState) return Response.redirect(appRedirect("error", "oauth_state_already_used"), 303);
  try {
    const configuration = oauthConfiguration(), verifier = await decrypt(stored.pkce_verifier_ciphertext);
    const token = await exchangeToken({ grant_type: "authorization_code", code, redirect_uri: configuration.redirectUri, code_verifier: verifier });
    const accessToken = text(token.access_token), sessionResult = await providerRequest("/v1.beta/oauth2_sessions/me", accessToken), companyResult = await providerRequest("/v1.beta/companies/me", accessToken);
    if (!sessionResult.response.ok || !companyResult.response.ok) throw Object.assign(new Error("provider_verification_failed"), { status: 502 });
    const session = object(sessionResult.payload), company = object(companyResult.payload);
    if (text(company.env) !== "production") throw Object.assign(new Error("provider_company_not_production"), { status: 409 });
    const { data: expected } = await adminClient.from("company_settings").select("siren,siret").eq("company_id", stored.company_id).maybeSingle();
    const expectedSiren = text(expected?.siren, String(expected?.siret || "").replace(/\D/g, "").slice(0, 9)).replace(/\D/g, "");
    const providerNumber = text(company.number).replace(/\D/g, "");
    if (expectedSiren && providerNumber && expectedSiren !== providerNumber.slice(0, 9)) throw Object.assign(new Error("provider_company_mismatch"), { status: 409 });
    const connection = connectionState(session), now = new Date().toISOString(), expiresIn = Math.max(60, Number(token.expires_in) || 3600);
    const { data: connector, error: connectorError } = await adminClient.from("platform_connectors").upsert({
      company_id: stored.company_id, connector_code: "SUPERPDP", provider_name: "SUPER PDP",
      connector_kind: "accredited_platform", environment: "production",
      status: connection.active ? "active" : "validation_required", is_simulation: false,
      production_enabled: false,
      base_url: API_URL, capabilities: { oauth: true, factur_x: true, cii: true, ubl: true, send: true, receive: true, directory: true },
      non_secret_configuration: { external_company_id: company.id == null ? null : String(company.id), external_company_number: text(company.number), external_company_name: text(company.trade_name, company.formal_name), verification_status: connection.companyVerification, verified_at: now },
      created_by: stored.user_id,
    }, { onConflict: "company_id,connector_code,environment" }).select("id").single();
    if (connectorError || !connector) throw Object.assign(new Error("connector_storage_failed"), { status: 502 });
    const authorizationPayload = {
      company_id: stored.company_id, connector_id: connector.id, environment: "production",
      provider_company_id: company.id == null ? null : String(company.id), provider_company_number: text(company.number),
      provider_company_name: text(company.trade_name, company.formal_name), company_verification_status: connection.companyVerification,
      user_identity_verification_status: connection.identityVerification || null, access_token_ciphertext: await encrypt(accessToken),
      refresh_token_ciphertext: token.refresh_token ? await encrypt(text(token.refresh_token)) : null,
      token_type: text(token.token_type, "Bearer"), granted_scope: text(token.scope),
      access_token_expires_at: new Date(Date.now() + expiresIn * 1000).toISOString(), authorized_by: stored.user_id,
      authorized_at: now, revoked_by: null, revoked_at: null, last_verified_at: now, last_error_code: null,
    };
    const { data: authorization, error: authorizationError } = await adminClient.from("superpdp_company_authorizations").upsert(authorizationPayload, { onConflict: "company_id" }).select("id").single();
    if (authorizationError || !authorization) throw Object.assign(new Error("authorization_storage_failed"), { status: 502 });
    const { error: activateError } = await adminClient.from("platform_connectors").update({
      production_enabled: connection.active,
      credential_secret_ref: `superpdp_company_authorizations:${authorization.id}`,
    }).eq("id", connector.id);
    if (activateError) throw Object.assign(new Error("connector_storage_failed"), { status: 502 });
    await adminClient.from("superpdp_consent_events").insert({ company_id: stored.company_id, authorization_id: authorization.id, actor_id: stored.user_id, event_type: "authorization_granted", evidence: { provider: "SUPER PDP", company_verification_status: connection.companyVerification, user_identity_verification_status: connection.identityVerification, provider_company_number: text(company.number) } });
    return Response.redirect(appRedirect("connected"), 303);
  } catch (callbackError) {
    const errorCode = text((callbackError as Error).message, "oauth_callback_failed");
    console.error("[PILOZ SUPER PDP OAuth] callback failed", { code: errorCode, companyId: stored.company_id });
    await adminClient.from("superpdp_consent_events").insert({ company_id: stored.company_id, actor_id: stored.user_id, event_type: "authorization_failed", evidence: { code: errorCode } });
    return Response.redirect(appRedirect("error", errorCode), 303);
  }
}
async function activateDirectory(adminClient: SupabaseClient, companyId: string, actorId: string) {
  const authorization = await authorizationFor(adminClient, companyId), token = await validAccessToken(adminClient, authorization);
  const identifier = text(authorization.provider_company_number).replace(/\D/g, "").slice(0, 9);
  if (identifier.length !== 9) throw Object.assign(new Error("company_siren_required"), { status: 409 });
  await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, authorization_id: authorization.id, actor_id: actorId, event_type: "directory_requested", evidence: { directory: "ppf", identifier } });
  const result = await providerRequest("/v1.beta/directory_entries", token, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ directory: "ppf", identifier }) });
  const payload = object(result.payload);
  if (!result.response.ok && result.response.status !== 409) {
    await adminClient.from("superpdp_company_authorizations").update({ directory_status: "error", last_error_code: text(payload.code, payload.error, "directory_activation_failed"), last_error_at: new Date().toISOString() }).eq("id", authorization.id);
    await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, authorization_id: authorization.id, actor_id: actorId, event_type: "directory_failed", evidence: { status: result.response.status, code: text(payload.code, payload.error) } });
    throw Object.assign(new Error("directory_activation_failed"), { status: 502 });
  }
  const status = ["created", "active", "ok", "enabled"].includes(text(payload.status).toLowerCase()) ? "active" : "pending";
  await adminClient.from("superpdp_company_authorizations").update({ directory_status: status, directory_entry_id: payload.id == null ? authorization.directory_entry_id : String(payload.id), last_error_code: null }).eq("id", authorization.id);
  await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, authorization_id: authorization.id, actor_id: actorId, event_type: status === "active" ? "directory_activated" : "directory_requested", evidence: { directory: "ppf", identifier, provider_entry_id: payload.id || null, provider_status: text(payload.status) } });
  return { ok: true, directoryStatus: status, providerStatus: text(payload.status) };
}
async function disconnect(adminClient: SupabaseClient, companyId: string, actorId: string) {
  const authorization = await authorizationFor(adminClient, companyId), now = new Date().toISOString();
  await adminClient.from("superpdp_company_authorizations").update({ access_token_ciphertext: null, refresh_token_ciphertext: null, revoked_by: actorId, revoked_at: now, last_error_code: null }).eq("id", authorization.id);
  await adminClient.from("platform_connectors").update({ status: "suspended", production_enabled: false, credential_secret_ref: null }).eq("id", authorization.connector_id);
  await adminClient.from("superpdp_jobs").update({ status: "cancelled", completed_at: now }).eq("company_id", companyId).in("status", ["pending", "retry_scheduled"]);
  await adminClient.from("superpdp_consent_events").insert({ company_id: companyId, authorization_id: authorization.id, actor_id: actorId, event_type: "authorization_revoked", evidence: { provider: "SUPER PDP" } });
  return { ok: true };
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "", anon = Deno.env.get("SUPABASE_ANON_KEY") || "", serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !anon || !serviceRole) return json({ error: "Service non configuré." }, 503);
  const adminClient = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false, autoRefreshToken: false } });
  if (req.method === "GET" && new URL(req.url).pathname.endsWith("/callback")) return oauthCallback(req, adminClient);
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const userClient = createClient(supabaseUrl, anon, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide." }, 401);
  let body: JsonObject;
  try { body = object(JSON.parse(await req.text())); } catch { return json({ error: "Demande invalide." }, 400); }
  const companyId = safeUuid(body.companyId), action = text(body.action);
  if (!companyId) return json({ error: "Entreprise invalide." }, 400);
  try {
    await requireManager(userClient, companyId);
    if (action === "start") return json(await startAuthorization(userClient, adminClient, { id: user.id, email: user.email }, companyId));
    if (action === "refresh") return json(await refreshVerification(adminClient, companyId, user.id));
    if (action === "activate_directory") return json(await activateDirectory(adminClient, companyId, user.id));
    if (action === "disconnect") return json(await disconnect(adminClient, companyId, user.id));
    if (action === "status") {
      const { data, error } = await userClient.rpc("get_superpdp_connection_status", { target_company_id: companyId });
      if (error) throw Object.assign(new Error("status_unavailable"), { status: 502 });
      return json(data);
    }
    return json({ error: "Action inconnue." }, 400);
  } catch (error) {
    const code = text((error as Error).message, "superpdp_oauth_failed");
    const status = Math.max(400, Math.min(599, Number((error as { status?: number }).status || 502)));
    const messages: Record<string, string> = {
      forbidden: "Vous n’avez pas l’autorisation de gérer la facturation électronique.",
      production_credentials_missing: "La connexion serveur SUPER PDP de production n’est pas encore configurée.",
      token_encryption_key_missing: "La clé de chiffrement des autorisations SUPER PDP n’est pas configurée.",
      company_settings_missing: "Complétez d’abord les informations de votre entreprise.",
      company_siren_required: "Renseignez un SIREN valide avant d’activer SUPER PDP.",
      authorization_missing: "Cette entreprise n’est pas encore reliée à SUPER PDP.",
      reauthorization_required: "L’autorisation SUPER PDP a expiré. Reconnectez l’entreprise.",
      provider_verification_failed: "SUPER PDP n’a pas pu confirmer l’état de cette entreprise.",
      directory_activation_failed: "L’inscription de l’entreprise dans l’annuaire n’a pas abouti.",
    };
    console.error("[PILOZ SUPER PDP OAuth] request failed", { code, status, companyId, action });
    return json({ error: messages[code] || "L’opération SUPER PDP n’a pas pu aboutir.", code }, status);
  }
});
