import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFImage, type PDFPage } from "npm:pdf-lib@1.17.1";
import { corsHeaders, json } from "../_shared/http.ts";

type SnapshotPayload = {
  schema_version?: number;
  captured_at?: string;
  document?: Record<string, unknown>;
  issuer?: Record<string, unknown>;
  client?: Record<string, unknown>;
  document_settings?: Record<string, unknown>;
  lines?: Array<Record<string, unknown>>;
  logo?: Record<string, unknown>;
};

type LogoAsset = { bytes: Uint8Array; mimeType: "image/png" | "image/jpeg" };

const A4: [number, number] = [595.28, 841.89];
const accent = rgb(0.05, 0.43, 0.45);
const ink = rgb(0.08, 0.12, 0.2);
const muted = rgb(0.38, 0.43, 0.51);
const rule = rgb(0.85, 0.88, 0.91);
const pale = rgb(0.96, 0.97, 0.98);

function text(value: unknown) {
  return String(value ?? "")
    .normalize("NFC")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/\u2026/g, "...")
    .replace(/[\u00A0\u202F]/g, " ")
    .replace(/€/g, "EUR")
    .replace(/œ/g, "oe")
    .replace(/Œ/g, "OE")
    .replace(/[^\x20-\x7E\u00A0-\u00FF]/g, "?");
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function amount(value: unknown, currency = "EUR") {
  try {
    return text(new Intl.NumberFormat("fr-FR", { style: "currency", currency }).format(Number(value) || 0));
  } catch {
    return `${(Number(value) || 0).toFixed(2)} ${text(currency)}`;
  }
}

function date(value: unknown) {
  if (!value) return "-";
  const parsed = new Date(String(value).length === 10 ? `${value}T12:00:00Z` : String(value));
  return Number.isNaN(parsed.valueOf()) ? "-" : new Intl.DateTimeFormat("fr-FR").format(parsed);
}

function partyName(value: Record<string, unknown>) {
  return text(value.legal_name || value.trade_name || [value.first_name, value.last_name].filter(Boolean).join(" ") || "-");
}

function address(value: Record<string, unknown>) {
  return text([
    value.address_line1 || value.address_line_1,
    value.address_line2 || value.address_line_2,
    [value.postal_code, value.city].filter(Boolean).join(" "),
    value.country || value.country_code,
  ].filter(Boolean).join(", "));
}

function splitToken(font: PDFFont, value: string, size: number, maxWidth: number) {
  if (font.widthOfTextAtSize(value, size) <= maxWidth) return [value];
  const chunks: string[] = [];
  let chunk = "";
  for (const character of value) {
    const candidate = chunk + character;
    if (!chunk || font.widthOfTextAtSize(candidate, size) <= maxWidth) chunk = candidate;
    else { chunks.push(chunk); chunk = character; }
  }
  if (chunk) chunks.push(chunk);
  return chunks;
}

function wrap(font: PDFFont, value: unknown, size: number, maxWidth: number) {
  const words = text(value).split(/\s+/).filter(Boolean).flatMap(word => splitToken(font, word, size, maxWidth));
  if (!words.length) return [""];
  const lines: string[] = [];
  let line = "";
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (!line || font.widthOfTextAtSize(candidate, size) <= maxWidth) line = candidate;
    else {
      lines.push(line);
      line = word;
    }
  }
  if (line) lines.push(line);
  return lines;
}

function fit(font: PDFFont, value: unknown, size: number, maxWidth: number) {
  const source = text(value);
  if (font.widthOfTextAtSize(source, size) <= maxWidth) return source;
  const suffix = "...";
  let output = source;
  while (output && font.widthOfTextAtSize(output + suffix, size) > maxWidth) output = output.slice(0, -1);
  return output + suffix;
}

function limitedLines(font: PDFFont, value: unknown, size: number, maxWidth: number, maxLines: number) {
  const all = wrap(font, value, size, maxWidth);
  const lines = all.slice(0, maxLines);
  if (all.length > maxLines && lines.length) lines[lines.length - 1] = fit(font, `${lines.at(-1)}...`, size, maxWidth);
  return lines;
}

function right(page: PDFPage, font: PDFFont, value: unknown, x: number, y: number, size = 9, color = ink, maxWidth = 245) {
  const output = fit(font, value, size, maxWidth);
  page.drawText(output, { x: x - font.widthOfTextAtSize(output, size), y, size, font, color });
}

async function buildPdf(payload: SnapshotPayload, logo?: LogoAsset) {
  const pdf = await PDFDocument.create();
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let embeddedLogo: PDFImage | null = null;
  if (logo) {
    try { embeddedLogo = logo.mimeType === "image/png" ? await pdf.embedPng(logo.bytes) : await pdf.embedJpg(logo.bytes); }
    catch { embeddedLogo = null; }
  }
  const doc = payload.document || {};
  const issuer = payload.issuer || {};
  const client = payload.client || {};
  const settings = payload.document_settings || {};
  const metadata = record(doc.metadata);
  const currency = text(doc.currency || "EUR");
  const kind = doc.document_type === "quote" ? "Devis"
    : doc.document_type === "deposit_invoice" ? "Facture d'acompte"
    : doc.document_type === "balance_invoice" ? "Facture de solde"
    : doc.document_type === "credit_note" ? "Avoir"
    : doc.document_type === "proforma_invoice" ? "Facture pro forma"
    : doc.document_type === "invoice" && metadata.conversion === "progress" ? "Facture de situation"
    : doc.document_type === "invoice" ? "Facture" : "Document";
  const number = text(doc.number || "Brouillon");
  const pages: PDFPage[] = [];
  let page!: PDFPage;
  let y = 0;

  const drawColumns = () => {
    page.drawRectangle({ x: 42, y: y - 4, width: 511, height: 20, color: pale });
    page.drawText("DESIGNATION", { x: 48, y: y + 3, size: 7, font: bold, color: muted });
    right(page, bold, "QTE", 360, y + 3, 7, muted);
    right(page, bold, "PRIX U. HT", 438, y + 3, 7, muted);
    right(page, bold, "TVA", 482, y + 3, 7, muted);
    right(page, bold, "TOTAL HT", 547, y + 3, 7, muted);
    y -= 16;
  };

  const addPage = (continuation = false) => {
    const firstPage = pages.length === 0;
    page = pdf.addPage(A4);
    pages.push(page);
    page.drawRectangle({ x: 0, y: 826, width: A4[0], height: 16, color: accent });
    page.drawText(fit(bold, kind.toUpperCase(), 10, 270), { x: 42, y: 787, size: 10, font: bold, color: accent });
    page.drawText(fit(bold, number, 19, 270), { x: 42, y: 765, size: 19, font: bold, color: ink });
    if (firstPage && embeddedLogo) {
      const scale = Math.min(140 / embeddedLogo.width, 44 / embeddedLogo.height, 1);
      page.drawImage(embeddedLogo, { x: 42, y: 704, width: embeddedLogo.width * scale, height: embeddedLogo.height * scale });
    }
    const issuerName = partyName(issuer);
    right(page, bold, issuerName, 553, 787, 10, ink, 245);
    right(page, regular, address(issuer), 553, 772, 8, muted, 245);
    if (issuer.email) right(page, regular, issuer.email, 553, 760, 8, muted, 245);
    if (issuer.phone_e164 || issuer.phone) right(page, regular, issuer.phone_e164 || issuer.phone, 553, 748, 8, muted, 245);
    if (issuer.siret) right(page, regular, `SIRET ${issuer.siret}`, 553, 736, 8, muted, 245);
    if (issuer.vat_number) right(page, regular, `TVA ${issuer.vat_number}`, 553, 724, 8, muted, 245);
    y = continuation ? 696 : 692;
    if (continuation) drawColumns();
  };

  addPage();
  page.drawRectangle({ x: 42, y: 620, width: 511, height: 62, color: pale });
  page.drawText("Date d'emission", { x: 52, y: 663, size: 8, font: bold, color: muted });
  page.drawText(date(doc.issue_date), { x: 132, y: 663, size: 8, font: regular, color: ink });
  page.drawText(doc.document_type === "quote" ? "Date de validite" : "Date d'echeance", { x: 52, y: 648, size: 8, font: bold, color: muted });
  page.drawText(date(doc.document_type === "quote" ? doc.validity_date : doc.due_date), { x: 132, y: 648, size: 8, font: regular, color: ink });
  if (doc.subject) {
    page.drawText("Objet", { x: 52, y: 633, size: 8, font: bold, color: muted });
    page.drawText(fit(regular, doc.subject, 8, 193), { x: 132, y: 633, size: 8, font: regular, color: ink });
  }
  page.drawText("DESTINATAIRE", { x: 345, y: 663, size: 7, font: bold, color: muted });
  page.drawText(fit(bold, partyName(client), 10, 198), { x: 345, y: 648, size: 10, font: bold, color: ink });
  limitedLines(regular, address(client), 8, 198, 2).forEach((line, index) => page.drawText(line, { x: 345, y: 634 - index * 11, size: 8, font: regular, color: muted }));
  y = 590;
  drawColumns();

  for (const line of payload.lines || []) {
    const lineType = text(line.line_type || "item");
    if (lineType === "page_break") {
      addPage(true);
      continue;
    }
    const structural = ["title", "subtitle", "section", "text", "comment", "subtotal"].includes(lineType);
    const nameLines = limitedLines(structural ? bold : regular, line.name || line.description || "Designation", structural ? 9 : 8, 225, structural ? 8 : 5);
    const descriptionLines = structural || !line.description ? [] : limitedLines(regular, line.description, 7, 225, 2);
    const rowHeight = Math.max(24, 10 + nameLines.length * 10 + descriptionLines.length * 9);
    if (y - rowHeight < 106) addPage(true);
    if (structural) {
      page.drawRectangle({ x: 42, y: y - rowHeight + 6, width: 511, height: rowHeight, color: pale });
      nameLines.forEach((value, index) => page.drawText(value, { x: 48, y: y - 7 - index * 10, size: 9, font: bold, color: ink }));
      if (lineType === "subtotal") right(page, bold, amount(line.total_excl_tax, currency), 547, y - 7, 9, ink, 85);
    } else {
      nameLines.forEach((value, index) => page.drawText(value, { x: 48, y: y - 7 - index * 10, size: 8, font: index === 0 ? bold : regular, color: ink }));
      descriptionLines.forEach((value, index) => page.drawText(value, { x: 48, y: y - 7 - nameLines.length * 10 - index * 9, size: 7, font: regular, color: muted }));
      right(page, regular, `${Number(line.quantity || 0).toLocaleString("fr-FR")} ${text(line.unit || "")}`, 360, y - 7, 8, ink, 58);
      right(page, regular, amount(line.unit_price, currency), 438, y - 7, 8, ink, 72);
      right(page, regular, `${Number(line.tax_rate || 0).toLocaleString("fr-FR")} %`, 482, y - 7, 8, ink, 40);
      right(page, bold, amount(line.total_excl_tax ?? ((Number(line.quantity) || 0) * (Number(line.unit_price) || 0)), currency), 547, y - 7, 8, ink, 62);
    }
    page.drawLine({ start: { x: 42, y: y - rowHeight + 4 }, end: { x: 553, y: y - rowHeight + 4 }, thickness: 0.5, color: rule });
    y -= rowHeight;
  }

  if (y < 185) addPage(false);
  const totalsY = Math.min(y - 22, 190);
  const vat = new Map<number, { base: number; tax: number }>();
  for (const line of payload.lines || []) {
    if (!["item", "free_item", "discount"].includes(text(line.line_type || "item")) || line.optional) continue;
    const rate = Number(line.tax_rate) || 0;
    const base = Number(line.total_excl_tax ?? ((Number(line.quantity) || 0) * (Number(line.unit_price) || 0))) || 0;
    const tax = Number(line.total_tax ?? base * rate / 100) || 0;
    const current = vat.get(rate) || { base: 0, tax: 0 };
    vat.set(rate, { base: current.base + base, tax: current.tax + tax });
  }
  page.drawText("DETAIL TVA", { x: 42, y: totalsY + 3, size: 7, font: bold, color: muted });
  [...vat.entries()].sort((a, b) => a[0] - b[0]).slice(0, 5).forEach(([rate, values], index) => {
    const rowY = totalsY - 13 - index * 12;
    page.drawText(`${rate.toLocaleString("fr-FR")} %`, { x: 42, y: rowY, size: 7, font: regular, color: ink });
    right(page, regular, `Base ${amount(values.base, currency)}`, 205, rowY, 7, muted, 135);
    right(page, regular, `TVA ${amount(values.tax, currency)}`, 330, rowY, 7, muted, 115);
  });
  page.drawRectangle({ x: 354, y: totalsY - 64, width: 199, height: 76, color: pale });
  page.drawText("Total HT", { x: 374, y: totalsY - 7, size: 9, font: bold, color: ink });
  right(page, regular, amount(doc.total_excl_tax, currency), 538, totalsY - 7, 9);
  page.drawText("TVA", { x: 374, y: totalsY - 27, size: 9, font: bold, color: ink });
  right(page, regular, amount(doc.total_tax, currency), 538, totalsY - 27, 9);
  page.drawLine({ start: { x: 370, y: totalsY - 37 }, end: { x: 538, y: totalsY - 37 }, thickness: 1, color: ink });
  page.drawText("Total TTC", { x: 374, y: totalsY - 54, size: 10, font: bold, color: ink });
  right(page, bold, amount(doc.total_incl_tax, currency), 538, totalsY - 54, 10);
  const footerNote = [doc.public_notes, settings.visible_mention, settings.legal_notice, settings.collection_fee_notice].filter(Boolean).join(" | ");
  limitedLines(regular, footerNote, 7, 500, 4).forEach((line, index) => page.drawText(line, { x: 42, y: 76 - index * 9, size: 7, font: regular, color: muted }));
  const bank = [settings.bank_account_holder, settings.iban && `IBAN ${settings.iban}`, settings.bic && `BIC ${settings.bic}`].filter(Boolean).join(" - ");
  if (bank) page.drawText(fit(regular, bank, 7, 500), { x: 42, y: 38, size: 7, font: regular, color: muted });
  page.drawText(fit(regular, [doc.payment_terms, doc.payment_method].filter(Boolean).join(" - "), 7, 420), { x: 42, y: 27, size: 7, font: regular, color: muted });

  pages.forEach((current, index) => {
    const label = `${index + 1} / ${pages.length}`;
    right(current, regular, label, 553, 18, 7, muted);
  });
  pdf.setTitle(`${kind} ${number}`);
  pdf.setAuthor(partyName(issuer));
  pdf.setCreator("PILOZ");
  pdf.setProducer("PILOZ document lifecycle");
  const capturedAt = new Date(payload.captured_at || String(doc.finalized_at || doc.validated_at || doc.updated_at || doc.issue_date || ""));
  const pdfDate = Number.isNaN(capturedAt.valueOf()) ? new Date(0) : capturedAt;
  pdf.setCreationDate(pdfDate);
  pdf.setModificationDate(pdfDate);
  return pdf.save();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function failureCode(error: unknown) {
  const value = record(error);
  const candidate = String(value.code || (error instanceof Error ? error.message : "pdf_generation_failed"));
  return candidate.toLowerCase().replace(/[^a-z0-9_.:-]+/g, "_").slice(0, 120) || "pdf_generation_failed";
}

async function sha256Hex(bytes: Uint8Array) {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)].map(value => value.toString(16).padStart(2, "0")).join("");
}

function isPdf(bytes: Uint8Array) {
  return bytes.byteLength >= 5 && bytes.byteLength <= 10 * 1024 * 1024
    && bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46 && bytes[4] === 0x2d;
}

async function completePdfJob(
  admin: SupabaseClient<any, "public", "public", any, any>,
  jobId: string,
  claimToken: string,
  path: string,
  sha256: string,
) {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const { data, error } = await admin.rpc("complete_document_pdf_job", {
      target_job_id: jobId,
      target_claim_token: claimToken,
      target_storage_path: path,
      target_sha256: sha256,
    });
    if (!error) return data;
    lastError = error;
  }
  const code = failureCode(lastError);
  throw Object.assign(new Error("pdf_completion_failed"), { code });
}

async function loadFrozenLogo(
  userClient: SupabaseClient<any, "public", "public", any, any>,
  payload: SnapshotPayload,
  companyId: string,
): Promise<LogoAsset | undefined> {
  const logo = record(payload.logo);
  const storagePath = String(logo.storage_path || "");
  const mimeType = String(logo.mime_type || "");
  const size = Number(logo.size_bytes) || 0;
  if (!storagePath || !["image/png", "image/jpeg"].includes(mimeType) || size < 1 || size > 5 * 1024 * 1024) return undefined;
  if (!storagePath.startsWith(`${companyId}/logos/`) || storagePath.includes("..")) return undefined;
  try {
    const { data, error } = await userClient.storage.from("company-assets").download(storagePath);
    if (error || !data || data.size > 5 * 1024 * 1024) return undefined;
    return { bytes: new Uint8Array(await data.arrayBuffer()), mimeType: mimeType as LogoAsset["mimeType"] };
  } catch {
    console.warn("[PILOZ PDF] frozen logo unavailable", { code: "logo_download_failed" });
    return undefined;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Methode non autorisee" }, 405);
  const authorization = req.headers.get("authorization");
  if (!authorization) return json({ error: "Authentification requise" }, 401);
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Configuration serveur incomplete" }, 503);

  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Session invalide" }, 401);
  const body = await req.json().catch(() => null) as { documentId?: string } | null;
  if (!body?.documentId || !UUID.test(body.documentId)) return json({ error: "Document invalide" }, 400);

  const { data: claimData, error: claimError } = await userClient.rpc("claim_document_pdf_job", {
    target_document_id: body.documentId,
  });
  if (claimError) {
    const code = failureCode(claimError);
    console.error("[PILOZ PDF] claim refused", { code });
    const status = code.includes("not_found") ? 404 : code.includes("not_finalized") ? 409 : code.includes("authentication") ? 401 : 503;
    return json({ error: status === 404 ? "Document final introuvable" : status === 409 ? "Le document doit etre finalise" : "Le service PDF est temporairement indisponible" }, status);
  }
  const claim = record(claimData);
  if (claim.ready && claim.path) return json({ generated: false, ready: true, path: claim.path, sha256: claim.sha256 || null });
  if (!claim.claimed) return json({ generated: false, ready: false, status: claim.status || "pending", retryAt: claim.retry_at || null }, 202);

  const jobId = String(claim.job_id || ""), claimToken = String(claim.claim_token || "");
  const snapshotId = String(claim.snapshot_id || ""), companyId = String(claim.company_id || "");
  const documentId = String(claim.document_id || "");
  const payload = record(claim.public_payload) as SnapshotPayload;
  if (![jobId, claimToken, snapshotId, companyId, documentId].every(value => UUID.test(value)) || !record(payload.document).document_type) {
    return json({ error: "Instantane final invalide" }, 500);
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let persistedObject = false;
  try {
    const logo = await loadFrozenLogo(userClient, payload, companyId);
    const bytes = await buildPdf(payload, logo);
    let sha256 = await sha256Hex(bytes);
    const path = `${companyId}/documents/${documentId}/${snapshotId}.pdf`;
    const { error: uploadError } = await admin.storage.from("company-files").upload(path, bytes, {
      contentType: "application/pdf",
      cacheControl: "31536000",
      upsert: false,
    });
    let recovered = false;
    if (uploadError) {
      // Un crash peut laisser l'objet immuable avant la validation SQL. Dans ce
      // cas on reprend exactement cet objet, au lieu de rester bloqué par
      // `upsert:false`. Les politiques Storage interdisent sa pré-création au
      // navigateur sous /documents/.
      const { data: existing, error: downloadError } = await admin.storage.from("company-files").download(path);
      if (downloadError || !existing) throw Object.assign(new Error("pdf_upload_failed"), { code: "pdf_upload_failed" });
      const existingBytes = new Uint8Array(await existing.arrayBuffer());
      if (!isPdf(existingBytes)) throw Object.assign(new Error("pdf_existing_object_invalid"), { code: "pdf_existing_object_invalid" });
      sha256 = await sha256Hex(existingBytes);
      recovered = true;
    }
    persistedObject = true;
    const completed = await completePdfJob(admin, jobId, claimToken, path, sha256);
    return json({ generated: !recovered, recovered, ready: true, path: record(completed).path || path, sha256 });
  } catch (error) {
    const code = failureCode(error);
    console.error("[PILOZ PDF] generation failed", { code });
    // Ne jamais supprimer ici : la complétion SQL a pu réussir malgré une
    // réponse réseau perdue. Un objet non encore attaché sera repris au prochain
    // bail grâce au chemin déterministe et à son SHA-256.
    const { error: failError } = await admin.rpc("fail_document_pdf_job", {
      target_job_id: jobId,
      target_claim_token: claimToken,
      target_error_code: code,
      target_retry_after_seconds: 60,
    });
    if (failError) console.error("[PILOZ PDF] failure state update failed", { code: failureCode(failError) });
    return json({ error: "Le PDF final n'a pas pu etre genere", retryable: true, objectPersisted: persistedObject }, 503);
  }
});
