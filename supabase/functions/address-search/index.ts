import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

const cache = new Map<string, { expires: number; payload: unknown }>();
const windows = new Map<string, number[]>();
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  const auth = req.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) return json({ error: "Authentification requise" }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL"), anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return json({ error: "Service mal configuré" }, 500);
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide" }, 401);
  const now=Date.now(),recent=(windows.get(user.id)||[]).filter(value=>now-value<60_000);
  if(recent.length>=80)return json({error:"Trop de recherches. Réessayez dans une minute."},429,{"Retry-After":"60"});
  recent.push(now);windows.set(user.id,recent);
  let body: { query?: string; postcode?: string };
  try { body = await req.json(); } catch { return json({ error: "Requête invalide" }, 400); }
  const query = String(body.query || "").trim().replace(/\s+/g, " ");
  if (query.length < 3 || query.length > 160) return json({ error: "Saisissez au moins 3 caractères." }, 400);
  const key = `${query.toLocaleLowerCase("fr")}:${body.postcode || ""}`;
  const hit = cache.get(key); if (hit && hit.expires > Date.now()) return json(hit.payload, 200, { "X-Cache": "HIT" });

  // Géoplateforme endpoint (the former api-adresse.data.gouv.fr endpoint is deprecated).
  const url = new URL("https://data.geopf.fr/geocodage/search");
  url.searchParams.set("q", query); url.searchParams.set("limit", "8");
  if (body.postcode) url.searchParams.set("postcode", String(body.postcode).replace(/\D/g, "").slice(0, 5));
  try {
    const response = await fetch(url, { headers: { Accept: "application/json", "User-Agent": "PILOZ-APP/1.0 contact@app.piloz.fr" } });
    if (!response.ok) return json({ error: "Service d’adresses indisponible." }, 502);
    const raw = await response.json();
    const results = (raw.features || []).map((feature: Record<string, any>) => {
      const p = feature.properties || {}; const coordinates = feature.geometry?.coordinates || [];
      return { label: p.label || p.name, addressLine1: [p.housenumber, p.street || p.name].filter(Boolean).join(" "), addressLine2: "",
        postalCode: p.postcode || null, city: p.city || p.municipality || null, department: p.department || null, region: p.region || null,
        countryCode: "FR", longitude: coordinates[0] ?? null, latitude: coordinates[1] ?? null, sourceId: p.id || null, source: "BAN / Géoplateforme" };
    });
    const payload = { results, retrievedAt: new Date().toISOString() };
    cache.set(key, { expires: Date.now() + 10 * 60_000, payload }); return json(payload);
  } catch { return json({ error: "Impossible de contacter le service d’adresses." }, 502); }
});
