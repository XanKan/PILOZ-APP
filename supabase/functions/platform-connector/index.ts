import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) return json({ error: "Connecteur non configuré." }, 503);
  const userClient = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide." }, 401);
  let body: { action?: string; companyId?: string; recordId?: string; operation?: string; idempotencyKey?: string };
  try { const raw = await req.text(); body = raw ? JSON.parse(raw) : {}; }
  catch { return json({ error: "Demande invalide." }, 400); }

  if (body.action === "configure_sandbox" && body.companyId) {
    const { data, error } = await userClient.rpc("create_platform_sandbox", { target_company_id: body.companyId });
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
});
