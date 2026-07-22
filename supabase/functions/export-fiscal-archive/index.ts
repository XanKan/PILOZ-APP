import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

const MAX_ARCHIVE_BYTES = 50 * 1024 * 1024;

function base64(bytes: Uint8Array) {
  let result = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    result += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(result);
}

async function sha256(value: Uint8Array | string) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map(byte => byte.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Méthode non autorisée." }, 405);
  const authorization = req.headers.get("Authorization") || "";
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Service d'archive non configuré." }, 503);

  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide." }, 401);
  let body: { archiveId?: string };
  try {
    const raw = await req.text();
    body = raw ? JSON.parse(raw) : {};
  } catch {
    return json({ error: "La demande d'archive est invalide." }, 400);
  }
  if (!body.archiveId) return json({ error: "Identifiant d'archive requis." }, 400);

  const { data: archive, error: archiveError } = await userClient.from("fiscal_archives")
    .select("*").eq("id", body.archiveId).maybeSingle();
  if (archiveError || !archive) return json({ error: "Archive introuvable ou accès refusé." }, 404);
  const { data: member } = await userClient.from("company_members").select("role")
    .eq("company_id", archive.company_id).eq("user_id", user.id).maybeSingle();
  if (!member || !["owner", "admin"].includes(member.role)) return json({ error: "Accès administrateur requis." }, 403);

  const { data: items, error: itemsError } = await userClient.from("fiscal_archive_items")
    .select("*").eq("archive_id", archive.id).order("relative_path");
  if (itemsError) return json({ error: "Le manifeste d'archive est indisponible." }, 500);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const files: Array<Record<string, unknown>> = [];
  let totalBytes = 0;
  try {
    for (const item of items || []) {
      if (item.content_status === "missing") throw new Error(`Élément manquant : ${item.relative_path}`);
      if (item.content_status === "embedded") {
        files.push({ relative_path: item.relative_path, encoding: "json", content: item.embedded_payload });
        continue;
      }
      const { data, error } = await admin.storage.from(item.storage_bucket).download(item.storage_path);
      if (error || !data) throw new Error(`Fichier inaccessible : ${item.relative_path}`);
      const bytes = new Uint8Array(await data.arrayBuffer());
      totalBytes += bytes.byteLength;
      if (totalBytes > MAX_ARCHIVE_BYTES) throw new Error("Archive supérieure à 50 Mo : utilisez une période plus courte.");
      const digest = await sha256(bytes);
      if (digest !== item.content_hash) throw new Error(`Empreinte PDF invalide : ${item.relative_path}`);
      files.push({ relative_path: item.relative_path, encoding: "base64", content: base64(bytes) });
    }
    const packageHash = await sha256(`${archive.manifest_hash}|${(items || []).map(item => item.content_hash).join("|")}`);
    const verificationStatus = archive.signature ? "not_verified" : "unsigned";
    const { error: registerError } = await userClient.rpc("register_fiscal_archive_export", {
      target_archive_id: archive.id,
      target_export_format: "json_bundle",
      target_package_hash: packageHash,
      target_verification_status: verificationStatus,
    });
    if (registerError) throw new Error("Impossible de tracer l'export de l'archive.");
    return json({
      format: archive.format_name,
      format_version: archive.format_version,
      manifest: archive.manifest,
      manifest_hash: archive.manifest_hash,
      database_archive_hash: archive.archive_hash,
      signature: archive.signature ? {
        status: "present_requires_public_key",
        value: archive.signature,
        key_id: archive.signature_key_id,
      } : { status: "not_configured" },
      package_hash: packageHash,
      files,
    }, 200, { "Content-Disposition": `attachment; filename="${archive.archive_number}.json"` });
  } catch (error) {
    console.error("fiscal_archive_export_failed", { archiveId: archive.id, code: error instanceof Error ? error.message : "unknown" });
    return json({ error: "L'archive n'a pas pu être exportée.", detail: error instanceof Error ? error.message : "Erreur inconnue" }, 409);
  }
});
