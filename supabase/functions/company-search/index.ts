import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

const cache = new Map<string, { expires: number; payload: unknown }>();
const windows = new Map<string, number[]>();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée" }, 405);
  const auth = req.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) return json({ error: "Authentification requise" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return json({ error: "Service mal configuré" }, 500);
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide" }, 401);

  const key = user.id;
  const now = Date.now();
  const recent = (windows.get(key) || []).filter((value) => now - value < 60_000);
  if (recent.length >= 50) return json({ error: "Trop de recherches. Réessayez dans une minute." }, 429, { "Retry-After": "60" });
  recent.push(now); windows.set(key, recent);

  let body: { query?: string; page?: number; perPage?: number };
  try { body = await req.json(); } catch { return json({ error: "Requête invalide" }, 400); }
  const query = String(body.query || "").trim().replace(/\s+/g, " ");
  if (query.length < 2 || query.length > 120) return json({ error: "Saisissez au moins 2 caractères." }, 400);
  const cacheKey = `${query.toLocaleLowerCase("fr")}:${body.page || 1}`;
  const cached = cache.get(cacheKey);
  if (cached && cached.expires > now) return json(cached.payload, 200, { "X-Cache": "HIT" });

  const url = new URL("https://recherche-entreprises.api.gouv.fr/search");
  url.searchParams.set("q", query.replace(/\D/g, "").length === query.replace(/\s/g, "").length ? query.replace(/\s/g, "") : query);
  url.searchParams.set("page", String(Math.max(1, body.page || 1)));
  url.searchParams.set("per_page", String(Math.min(10, Math.max(1, body.perPage || 8))));
  url.searchParams.set("limite_matching_etablissements", "25");
  try {
    const response = await fetch(url, { headers: { "User-Agent": "PILOZ-APP/1.0 contact@app.piloz.fr", Accept: "application/json" } });
    if (!response.ok) return json({ error: response.status === 429 ? "Service temporairement limité." : "Service entreprises indisponible." }, response.status === 429 ? 429 : 502);
    const raw = await response.json();
    const results = (raw.results || []).flatMap((company: Record<string, any>) => {
      const establishments = company.matching_etablissements?.length
        ? [...company.matching_etablissements, ...(company.siege && !company.matching_etablissements.some((est:Record<string,any>)=>est.siret===company.siege?.siret) ? [company.siege] : [])]
        : [company.siege];
      return establishments.filter(Boolean).map((est: Record<string, any>) => ({
        legalName: company.nom_complet || company.nom_raison_sociale || null,
        tradeName: company.nom_commercial || est.nom_commercial || null,
        legalForm: company.nature_juridique || company.libelle_nature_juridique || null,
        siren: company.siren || null, siret: est.siret || null, apeCode: company.activite_principale || est.activite_principale || null,
        activity: company.libelle_activite_principale || null, creationDate: company.date_creation || null,
        addressLine1: est.adresse || est.geo_adresse || null, postalCode: est.code_postal || null, city: est.libelle_commune || null,
        countryCode: "FR", administrativeStatus: est.etat_administratif || company.etat_administratif || null,
        isHeadOffice: Boolean(est.est_siege), establishmentKind: est.est_siege ? "head_office" : "secondary",
        latitude: est.latitude ? Number(est.latitude) : null, longitude: est.longitude ? Number(est.longitude) : null,
        source: "API Recherche d’Entreprises",
      }));
    });
    const payload = { results, total: raw.total_results || results.length, retrievedAt: new Date().toISOString() };
    cache.set(cacheKey, { expires: now + 5 * 60_000, payload });
    return json(payload);
  } catch { return json({ error: "Impossible de contacter le service entreprises." }, 502); }
});
