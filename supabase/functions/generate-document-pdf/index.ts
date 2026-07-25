import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { PDFDocument, PDFName, PDFString, StandardFonts, rgb, type PDFFont, type PDFImage, type PDFPage, type RGB } from "npm:pdf-lib@1.17.1";
import { corsHeaders, json } from "../_shared/http.ts";

type SnapshotPayload = {
  schema_version?: number;
  captured_at?: string;
  document?: Record<string, unknown>;
  issuer?: Record<string, unknown>;
  client?: Record<string, unknown>;
  recipient_contact?: Record<string, unknown>;
  billing_address?: Record<string, unknown>;
  delivery_address?: Record<string, unknown>;
  document_settings?: Record<string, unknown>;
  lines?: Array<Record<string, unknown>>;
  logo?: Record<string, unknown>;
  template?: Record<string, unknown>;
};

type LogoAsset = { bytes: Uint8Array; mimeType: "image/png" | "image/jpeg"; name?: string; width?: number };
type LayoutKey = "classic" | "modern" | "compact";

const A4: [number, number] = [595.28, 841.89];

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function hexToRgb(value: unknown, fallback: RGB): RGB {
  const source = String(value || "").trim();
  const match = /^#?([0-9a-f]{6})$/i.exec(source);
  if (!match) return fallback;
  const int = parseInt(match[1], 16);
  return rgb(((int >> 16) & 255) / 255, ((int >> 8) & 255) / 255, (int & 255) / 255);
}

const LAYOUT_KEYS: LayoutKey[] = ["classic", "modern", "compact"];

function resolveLayoutKey(value: unknown): LayoutKey {
  return LAYOUT_KEYS.includes(value as LayoutKey) ? (value as LayoutKey) : "classic";
}

const LAYOUT_DEFAULTS: Record<LayoutKey, { primary: string; secondary: string; heading: string; border: string; tableBackground: string; text: string; totals: string }> = {
  classic: { primary: "#0d6e73", secondary: "#0d6e73", heading: "#14202f", border: "#d9e0e8", tableBackground: "#f5f7f8", text: "#14202f", totals: "#0d6e73" },
  modern: { primary: "#0f766e", secondary: "#0891b2", heading: "#0f172a", border: "#cbd5e1", tableBackground: "#ecfeff", text: "#0f172a", totals: "#0f766e" },
  compact: { primary: "#334155", secondary: "#475569", heading: "#0f172a", border: "#e2e8f0", tableBackground: "#f8fafc", text: "#1e293b", totals: "#334155" },
};

function resolveColors(layoutKey: LayoutKey, overrides: Record<string, unknown>) {
  const base = LAYOUT_DEFAULTS[layoutKey];
  return {
    primary: hexToRgb(overrides.primary, hexToRgb(base.primary, rgb(0.05, 0.43, 0.45))),
    secondary: hexToRgb(overrides.secondary, hexToRgb(base.secondary, rgb(0.05, 0.43, 0.45))),
    heading: hexToRgb(overrides.heading || overrides.secondary, hexToRgb(base.heading, rgb(0.08, 0.12, 0.2))),
    border: hexToRgb(overrides.border, hexToRgb(base.border, rgb(0.85, 0.88, 0.91))),
    tableBackground: hexToRgb(overrides.tableBackground || overrides.background, hexToRgb(base.tableBackground, rgb(0.96, 0.97, 0.98))),
    text: hexToRgb(overrides.text, hexToRgb(base.text, rgb(0.08, 0.12, 0.2))),
    totals: hexToRgb(overrides.totals || overrides.primary, hexToRgb(base.totals, rgb(0.05, 0.43, 0.45))),
    muted: hexToRgb(overrides.muted, rgb(0.38, 0.43, 0.51)),
  };
}

function text(value: unknown) {
  return String(value ?? "")
    .normalize("NFC")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/\u2026/g, "...")
    .replace(/[\u00A0\u202F]/g, " ")
    .replace(/\u0153/g, "oe")
    .replace(/\u0152/g, "OE")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/[^\x20-\x7E\u00A0-\u00FF\u20AC\u00AB\u00BB]/g, "?");
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

function longDate(value: unknown) {
  if (!value) return "-";
  const parsed = new Date(String(value).length === 10 ? `${value}T12:00:00Z` : String(value));
  return Number.isNaN(parsed.valueOf()) ? "-" : text(new Intl.DateTimeFormat("fr-FR", {
    day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  }).format(parsed));
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

function resolveFooterTokens(value: unknown, issuer: Record<string, unknown>) {
  const tokens: Record<string, unknown> = {
    "@nomEntreprise": issuer.legal_name,
    "@nomCommercial": issuer.trade_name || issuer.legal_name,
    "@siren": issuer.siren,
    "@siret": issuer.siret,
    "@tva": issuer.vat_number,
    "@ape": issuer.ape_code,
    "@rcs": issuer.rcs_number,
    "@capitalSocial": issuer.social_capital,
    "@adresse": address(issuer),
    "@email": issuer.email,
    "@telephone": issuer.phone || issuer.phone_e164,
    "@site": issuer.website,
  };
  return Object.entries(tokens).reduce((output, [token, replacement]) => output.split(token).join(text(replacement)), String(value || ""));
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

function right(page: PDFPage, font: PDFFont, value: unknown, x: number, y: number, size = 9, color = rgb(0.08, 0.12, 0.2), maxWidth = 245) {
  const output = fit(font, value, size, maxWidth);
  page.drawText(output, { x: x - font.widthOfTextAtSize(output, size), y, size, font, color });
}

function centered(page: PDFPage, font: PDFFont, value: unknown, y: number, size = 7, color = rgb(0.38, 0.43, 0.51), maxWidth = 500) {
  const output = fit(font, value, size, maxWidth);
  page.drawText(output, { x: (A4[0] - font.widthOfTextAtSize(output, size)) / 2, y, size, font, color });
}

// Réglages numériques propres à chaque mise en page : hauteur de bandeau,
// densité des lignes, tailles de police. Les 3 partagent la même structure
// générale (bandeau -> métadonnées -> tableau -> totaux -> pied de page)
// mais avec un traitement visuel réellement différent.
const LAYOUT_METRICS: Record<LayoutKey, {
  bandHeight: number; titleSize: number; numberSize: number; lineNameSize: number; lineSize: number;
  rowPadding: number; metaBoxHeight: number; compact: boolean;
}> = {
  classic: { bandHeight: 16, titleSize: 10, numberSize: 19, lineNameSize: 8, lineSize: 8, rowPadding: 24, metaBoxHeight: 62, compact: false },
  modern: { bandHeight: 34, titleSize: 11, numberSize: 24, lineNameSize: 9, lineSize: 9, rowPadding: 28, metaBoxHeight: 68, compact: false },
  compact: { bandHeight: 12, titleSize: 9, numberSize: 15, lineNameSize: 7, lineSize: 7, rowPadding: 18, metaBoxHeight: 50, compact: true },
};

async function buildPdf(payload: SnapshotPayload, logo?: LogoAsset, footerLogos: LogoAsset[] = []) {
  const pdf = await PDFDocument.create();
  let regular = await pdf.embedFont(StandardFonts.Helvetica);
  let bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let embeddedLogo: PDFImage | null = null;
  if (logo) {
    try { embeddedLogo = logo.mimeType === "image/png" ? await pdf.embedPng(logo.bytes) : await pdf.embedJpg(logo.bytes); }
    catch { embeddedLogo = null; }
  }
  const embeddedFooterLogos: Array<{ image: PDFImage; width: number }> = [];
  for (const footerLogo of footerLogos.slice(0, 6)) {
    try {
      const image = footerLogo.mimeType === "image/png" ? await pdf.embedPng(footerLogo.bytes) : await pdf.embedJpg(footerLogo.bytes);
      embeddedFooterLogos.push({ image, width: Math.max(18, Math.min(60, Number(footerLogo.width || 64) * .45)) });
    } catch { /* Invalid or unsupported footer image: omit it without breaking the document. */ }
  }
  const doc = payload.document || {};
  const issuer = payload.issuer || {};
  const client = payload.client || {};
  const recipientContact = record(payload.recipient_contact);
  const billingAddress = record(payload.billing_address);
  const deliveryAddress = record(payload.delivery_address);
  const displayedClientAddress = Object.keys(billingAddress).length ? billingAddress : client;
  const settings = payload.document_settings || {};
  const metadata = record(doc.metadata);
  const currency = text(doc.currency || "EUR");

  const templateInfo = record(payload.template);
  const templateVersion = record(templateInfo.version);
  const templateFooter = record(templateInfo.footer);
  const frozenTheme = record(doc.theme_snapshot);
  const canonical = record(frozenTheme.configuration || templateVersion.configuration_json);
  const configuredFont = text(record(record(canonical.typography).content).family).toLowerCase();
  if (configuredFont.includes("times") || configuredFont.includes("georgia")) {
    regular = await pdf.embedFont(StandardFonts.TimesRoman); bold = await pdf.embedFont(StandardFonts.TimesRomanBold);
  } else if (configuredFont.includes("courier")) {
    regular = await pdf.embedFont(StandardFonts.Courier); bold = await pdf.embedFont(StandardFonts.CourierBold);
  }
  const canonicalStructure = text(record(canonical.structure).key);
  const canonicalLayout = canonicalStructure === "modern-color" || canonicalStructure === "editorial" ? "modern"
    : canonicalStructure === "compact-header" ? "compact" : "classic";
  const layoutKey = resolveLayoutKey(canonicalStructure ? canonicalLayout : templateVersion.layout_key);
  const colorSettings = Object.keys(record(canonical.colors)).length ? record(canonical.colors) : record(templateVersion.color_settings);
  const colors = resolveColors(layoutKey, colorSettings);
  const pageBackground = hexToRgb(colorSettings.background, rgb(1, 1, 1));
  const logoSettings = Object.keys(record(canonical.logo)).length ? record(canonical.logo) : record(templateVersion.logo_settings);
  const tableSettings = record(canonical.table);
  const footerSettings = record(canonical.footer);
  const decorationSettings = record(canonical.decoration);
  const spacingSettings = record(canonical.spacing);
  // The editor stores A4 margins in screen pixels. The PDF uses points, but the
  // same bounded numeric value keeps the visual rhythm stable and predictable.
  const contentLeft = Math.max(18, Math.min(120, Number(spacingSettings.left || 42)));
  const contentRight = A4[0] - Math.max(18, Math.min(120, Number(spacingSettings.right || 42)));
  const contentWidth = Math.max(330, contentRight - contentLeft);
  const clientColumnX = contentLeft + contentWidth * .59;
  const canonicalLinks = Array.isArray(canonical.links) ? canonical.links.map(value => record(value))
    .filter(link => /^https?:\/\//i.test(text(link.url))).slice(0, 3) : [];
  const contentBottomLimit = Math.max(96, Math.min(180, Number(spacingSettings.bottom || 48) + 62));
  const coloredTableHeader = tableSettings.colored_header !== false;
  const stripedTableRows = tableSettings.striped === true;
  const visibleTableBorders = tableSettings.borders !== false;
  const rawVisibleColumns = Array.isArray(tableSettings.columns) ? tableSettings.columns : templateVersion.visible_columns;
  const visibleColumns = Array.isArray(rawVisibleColumns)
    ? Object.fromEntries(rawVisibleColumns.map((column) => {
      const definition = record(column);
      return [text(definition.key || definition.id), definition.visible !== false];
    }).filter(([key]) => Boolean(key)))
    : record(rawVisibleColumns);
  const showDiscountColumn = visibleColumns.discount === true;
  const configuredColumns = Array.isArray(rawVisibleColumns)
    ? rawVisibleColumns.map(value => record(value)).filter(column => column.visible !== false)
      .sort((left, right) => Number(left.position || 0) - Number(right.position || 0))
    : [];
  const orderedColumns = configuredColumns.length ? configuredColumns : [
    { key: "description", label: "Désignation" }, { key: "quantity", label: "Qté" },
    { key: "unit_price", label: "Prix u. HT" }, { key: "tax_rate", label: "TVA" },
    { key: "total_excl_tax", label: "Total HT" }, { key: "total_incl_tax", label: "Total TTC" },
  ];
  const showLogo = logoSettings.enabled !== false && logoSettings.show !== false;
  const contentSize = text(record(record(canonical.typography).content).size);
  const fontScale = contentSize === "small" ? .88 : contentSize === "large" ? 1.12 : 1;
  const baseMetrics = LAYOUT_METRICS[layoutKey];
  const metrics = { ...baseMetrics, titleSize: baseMetrics.titleSize * fontScale, numberSize: baseMetrics.numberSize * fontScale, lineNameSize: baseMetrics.lineNameSize * fontScale, lineSize: baseMetrics.lineSize * fontScale };
  const hasFooterConfig = Object.keys(templateFooter).length > 0;
  const showLegalMentions = Object.keys(footerSettings).length ? footerSettings.show_legal !== false : hasFooterConfig ? templateFooter.show_legal_mentions !== false : true;
  const showPaymentTerms = hasFooterConfig ? templateFooter.show_payment_terms !== false : true;
  const showLatePenalties = hasFooterConfig ? templateFooter.show_late_penalties !== false : true;
  const showPageNumber = Object.keys(footerSettings).length ? footerSettings.show_page_number !== false : hasFooterConfig ? templateFooter.show_page_number !== false : true;
  const showBankDetails = Object.keys(footerSettings).length ? footerSettings.show_bank_details !== false : true;
  const showPilozBrand = footerSettings.show_piloz_brand === true;

  const issuerProfile = record(templateVersion.issuer_profile);
  const issuerName = text(issuerProfile.trade_name || issuer.trade_name || issuer.legal_name || "") || partyName(issuer);
  const issuerAddressText = issuerProfile.address ? text(issuerProfile.address) : address(issuer);
  const issuerEmail = text(issuerProfile.email || issuer.email || "");
  const issuerPhone = text(issuerProfile.phone || issuer.phone_e164 || issuer.phone || "");
  const saleTypeLabels: Record<string, string> = { goods: "Livraison de biens", services: "Prestation de services", goods_and_services: "Livraison de biens et prestation de services" };
  const saleTypeLabel = saleTypeLabels[String(issuerProfile.sale_type || "")] || "";

  const clientProfile = record(templateVersion.client_profile);
  const showClientEmail = clientProfile.show_email !== false;
  const showClientPhone = clientProfile.show_phone !== false;

  const paymentMethodsCatalog: Record<string, string> = { bank_transfer: "Virement bancaire", card: "Carte bancaire", check: "Chèque", cash: "Espèces", direct_debit: "Prélèvement SEPA" };
  const paymentTermsCatalog: Record<string, string> = { cash: "Comptant", receipt: "À réception", due_on_receipt: "À réception", end_of_month: "Fin de mois", days_30_end_of_month: "30 jours fin de mois" };
  const activeMethods = Array.isArray(templateVersion.payment_methods) && templateVersion.payment_methods.length
    ? (templateVersion.payment_methods as unknown[]).map(value => String(value)) : ["bank_transfer"];
  const acceptsBankTransfer = activeMethods.includes("bank_transfer");
  const rawPaymentTerm = text(doc.payment_terms || "");
  const rawPaymentMethod = text(doc.payment_method || "");
  const paymentTermLabel = paymentTermsCatalog[rawPaymentTerm]
    || (rawPaymentTerm.match(/^days_(\d+)$/)?.[1] ? `${rawPaymentTerm.match(/^days_(\d+)$/)?.[1]} jours` : rawPaymentTerm)
    || "—";
  const paymentMethodLabel = paymentMethodsCatalog[rawPaymentMethod] || rawPaymentMethod || "—";
  const depositMode = text(metadata.deposit_mode || (Number(metadata.deposit_amount_ttc) > 0 ? "amount" : "percent"));
  const depositValue = Number(metadata.deposit_value ?? (depositMode === "amount" ? metadata.deposit_amount_ttc : doc.deposit_rate)) || 0;
  const depositEnabled = Boolean(metadata.deposit_enabled ?? (Number(doc.deposit_rate) > 0)) && depositValue > 0 && doc.document_type === "quote";
  const depositAmount = depositMode === "amount" ? depositValue : (Number(doc.total_incl_tax) || 0) * depositValue / 100;
  const depositPercent = Number(doc.total_incl_tax) ? depositAmount / Number(doc.total_incl_tax) * 100 : depositMode === "percent" ? depositValue : 0;
  const depositText = depositEnabled
    ? depositMode === "percent"
      ? `Acompte de ${depositPercent.toLocaleString("fr-FR", { maximumFractionDigits: 2 })} % soit ${amount(depositAmount, currency)} à la signature`
      : `Acompte de ${amount(depositAmount, currency)}${depositPercent ? ` (soit ${depositPercent.toLocaleString("fr-FR", { maximumFractionDigits: 2 })} %)` : ""} à la signature`
    : "";

  const templateDocTitle = text(templateVersion.document_title || "");
  const kind = (doc.document_type === "quote" || doc.document_type === "invoice") && templateDocTitle ? templateDocTitle
    : doc.document_type === "quote" ? "Devis"
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
  const bankRows = [
    ["TITULAIRE", settings.bank_account_holder || issuer.trade_name || issuer.legal_name],
    ["IBAN :", settings.iban],
    ["BIC :", settings.bic],
  ].filter((row) => Boolean(text(row[1]))) as [string, unknown][];
  const drawBankDetails = (target: PDFPage, x: number, topY: number, width = 245, size = 6.5) => {
    if (!bankRows.length) return 0;
    const labelWidth = 62;
    const rowGap = 10;
    const boxHeight = 31 + bankRows.length * rowGap;
    target.drawRectangle({
      x,
      y: topY - boxHeight,
      width,
      height: boxHeight,
      color: colors.tableBackground,
      borderColor: colors.border,
      borderWidth: 0.7,
    });
    target.drawRectangle({ x, y: topY - boxHeight, width: 3, height: boxHeight, color: colors.primary });
    target.drawText("Coordonnées bancaires", { x: x + 11, y: topY - 15, size: 7, font: bold, color: colors.primary });
    bankRows.forEach(([label, value], index) => {
      const rowY = topY - 30 - index * rowGap;
      target.drawText(label, { x: x + 11, y: rowY, size: size - 0.4, font: bold, color: colors.text });
      target.drawText(fit(regular, value, size, width - labelWidth - 20), { x: x + 11 + labelWidth, y: rowY, size, font: regular, color: colors.muted });
    });
    return boxHeight;
  };

  const referenceLayout = layoutKey === "classic";
  const valueColumns = orderedColumns.filter(column => !["number", "reference", "description"].includes(text(column.key)));
  const numericWidth = Math.max(38, Math.min(72, (contentWidth * .56) / Math.max(valueColumns.length, 1)));
  const columnRight = new Map(valueColumns.map((column, index) => [text(column.key), contentRight - (valueColumns.length - index - 1) * numericWidth]));
  const descriptionWidth = Math.max(120, contentWidth - 8 - valueColumns.length * numericWidth);
  const columnLabel = (column: Record<string, unknown>) => text(column.label || ({
    number: "#", reference: "Référence", description: "Désignation", unit: "Unité", quantity: "Qté",
    unit_price: "Prix u. HT", discount: "Remise", tax_rate: "TVA", total_excl_tax: "Total HT", total_incl_tax: "Total TTC",
  } as Record<string, string>)[text(column.key)] || column.key);

  const drawColumns = () => {
    const headerColor = coloredTableHeader ? colors.primary : colors.tableBackground;
    const headerTextColor = coloredTableHeader ? rgb(1, 1, 1) : colors.secondary;
    page.drawRectangle({ x: contentLeft, y: y - 4, width: contentWidth, height: 20, color: headerColor });
    const descriptive = orderedColumns.filter(column => ["number", "reference", "description"].includes(text(column.key))).map(columnLabel).join(" · ") || "Désignation";
    page.drawText(fit(bold, descriptive, 7, descriptionWidth), { x: contentLeft + 6, y: y + 3, size: 7, font: bold, color: headerTextColor });
    valueColumns.forEach(column => right(page, bold, columnLabel(column), columnRight.get(text(column.key)) || contentRight, y + 3, 6.5, headerTextColor, numericWidth - 4));
    y -= 16;
  };

  const addPage = (continuation = false) => {
    const firstPage = pages.length === 0;
    page = pdf.addPage(A4);
    pages.push(page);
    page.drawRectangle({ x: 0, y: 0, width: A4[0], height: A4[1], color: pageBackground });
    if (text(decorationSettings.kind) !== "none" && text(decorationSettings.kind)) {
      const opacity = Math.max(0, Math.min(.35, Number(decorationSettings.opacity) || .12));
      const kindName = text(decorationSettings.kind);
      if (["frame", "lines"].includes(kindName)) {
        page.drawRectangle({ x: 18, y: 18, width: A4[0] - 36, height: A4[1] - 36, borderColor: colors.primary, borderWidth: kindName === "frame" ? 3 : 1, opacity });
      } else {
        page.drawCircle({ x: A4[0] - 35, y: A4[1] - 32, size: 115, color: colors.primary, opacity });
        page.drawRectangle({ x: A4[0] - 175, y: A4[1] - 42, width: 175, height: 18, color: colors.secondary, opacity });
      }
    }
    if (!referenceLayout) page.drawRectangle({ x: 0, y: A4[1] - metrics.bandHeight, width: A4[0], height: metrics.bandHeight, color: colors.primary });
    if (layoutKey === "modern") {
      page.drawRectangle({ x: 0, y: 826, width: A4[0], height: 10, color: colors.secondary });
    }
    if (continuation) {
      page.drawText(fit(bold, `${kind} ${number}`, 10, contentWidth * .52), { x: contentLeft, y: 800, size: 10, font: bold, color: colors.heading });
      right(page, bold, issuerName, contentRight, 800, 9, colors.heading, contentWidth * .43);
      y = 770;
      drawColumns();
      return;
    }
    if (firstPage && embeddedLogo && showLogo) {
      const maxWidth = Math.min(260, Math.max(48, Number(logoSettings.width || logoSettings.max_width) || 140));
      const scale = Math.min(maxWidth / embeddedLogo.width, 80 / embeddedLogo.height, 1);
      const width = embeddedLogo.width * scale;
      const height = embeddedLogo.height * scale;
      const logoAlignment = text(logoSettings.alignment || "left");
      const logoX = logoAlignment === "right" ? contentRight - width : logoAlignment === "center" ? (A4[0] - width) / 2 : contentLeft;
      page.drawImage(embeddedLogo, { x: logoX, y: 805 - height, width, height });
    }
    if (referenceLayout) {
      page.drawText(kind, { x: 42, y: 700, size: 13, font: bold, color: colors.primary });
      page.drawText("Numéro", { x: 42, y: 678, size: 8, font: bold, color: colors.text });
      page.drawText(fit(regular, number, 8, 150), { x: 145, y: 678, size: 8, font: regular, color: colors.text });
      page.drawText("Date d'émission", { x: 42, y: 663, size: 8, font: bold, color: colors.text });
      page.drawText(longDate(doc.issue_date), { x: 145, y: 663, size: 8, font: regular, color: colors.text });
      page.drawText(doc.document_type === "quote" ? "Date d'expiration" : "Date d'échéance", { x: 42, y: 648, size: 8, font: bold, color: colors.text });
      page.drawText(longDate(doc.document_type === "quote" ? doc.validity_date : doc.due_date), { x: 145, y: 648, size: 8, font: regular, color: colors.text });
      if (saleTypeLabel) {
        page.drawText("Type de service", { x: 42, y: 633, size: 8, font: bold, color: colors.text });
        page.drawText(fit(regular, saleTypeLabel, 8, 150), { x: 145, y: 633, size: 8, font: regular, color: colors.text });
      }
      right(page, bold, issuerName, 553, 800, 9, colors.heading, 208);
      limitedLines(regular, issuerAddressText, 8, 208, 2).forEach((line, index) => right(page, regular, line, 553, 786 - index * 11, 8, colors.text, 208));
      if (issuerEmail) right(page, regular, issuerEmail, 553, 764, 8, colors.text, 208);
      if (issuerPhone) right(page, regular, issuerPhone, 553, 752, 8, colors.text, 208);
      if (issuer.siret) right(page, regular, `SIRET ${issuer.siret}`, 553, 740, 8, colors.text, 208);
      if (issuer.vat_number) right(page, regular, `TVA ${issuer.vat_number}`, 553, 728, 8, colors.text, 208);
    } else {
      page.drawText(fit(bold, kind.toUpperCase(), metrics.titleSize, 270), { x: 42, y: 700, size: metrics.titleSize, font: bold, color: colors.primary });
      page.drawText(fit(bold, number, metrics.numberSize, 270), { x: 42, y: 680, size: metrics.numberSize, font: bold, color: colors.heading });
      right(page, bold, issuerName, 553, 787, 10, colors.heading, 245);
      right(page, regular, issuerAddressText, 553, 772, 8, colors.muted, 245);
      if (issuerEmail) right(page, regular, issuerEmail, 553, 760, 8, colors.muted, 245);
      if (issuerPhone) right(page, regular, issuerPhone, 553, 748, 8, colors.muted, 245);
      if (issuer.siret) right(page, regular, `SIRET ${issuer.siret}`, 553, 736, 8, colors.muted, 245);
      if (issuer.vat_number) right(page, regular, `TVA ${issuer.vat_number}`, 553, 724, 8, colors.muted, 245);
    }
    y = referenceLayout ? 606 : 692;
  };

  const clientContactLines: string[] = [];
  const recipientName = [recipientContact.civility, recipientContact.first_name, recipientContact.last_name]
    .filter(Boolean).join(" ");
  if (recipientName) clientContactLines.push(text(`À l'attention de ${recipientName}`));
  if (recipientContact.job_title) clientContactLines.push(text(recipientContact.job_title));
  if (showClientEmail && (recipientContact.email || client.email)) clientContactLines.push(text(recipientContact.email || client.email));
  if (showClientPhone && (recipientContact.phone_e164 || recipientContact.mobile_e164 || client.phone_e164 || client.phone)) {
    clientContactLines.push(text(recipientContact.phone_e164 || recipientContact.mobile_e164 || client.phone_e164 || client.phone));
  }
  if (Object.keys(deliveryAddress).length) {
    clientContactLines.push(text(`Livraison : ${address(deliveryAddress)}`));
  }
  const metaBoxHeight = metrics.metaBoxHeight + clientContactLines.length * 10;

  addPage();
  if (!referenceLayout) page.drawRectangle({ x: contentLeft, y: 662 - metaBoxHeight, width: contentWidth, height: metaBoxHeight, color: colors.tableBackground });
  const metaTop = referenceLayout ? 700 : 643;
  if (!referenceLayout) {
    page.drawText("Date d'emission", { x: 52, y: metaTop, size: 8, font: bold, color: colors.muted });
    page.drawText(date(doc.issue_date), { x: 132, y: metaTop, size: 8, font: regular, color: colors.text });
    page.drawText(doc.document_type === "quote" ? "Date de validite" : "Date d'echeance", { x: 52, y: metaTop - 15, size: 8, font: bold, color: colors.muted });
    page.drawText(date(doc.document_type === "quote" ? doc.validity_date : doc.due_date), { x: 132, y: metaTop - 15, size: 8, font: regular, color: colors.text });
    if (doc.subject) {
      page.drawText("Objet", { x: 52, y: metaTop - 30, size: 8, font: bold, color: colors.muted });
      page.drawText(fit(regular, doc.subject, 8, 193), { x: 132, y: metaTop - 30, size: 8, font: regular, color: colors.text });
    }
    if (saleTypeLabel) {
      page.drawText("Type de service", { x: 52, y: metaTop - 45, size: 8, font: bold, color: colors.muted });
      page.drawText(fit(regular, saleTypeLabel, 8, 193), { x: 132, y: metaTop - 45, size: 8, font: regular, color: colors.text });
    }
  }
  if (canonicalStructure === "boxed-client") page.drawRectangle({ x: clientColumnX - 9, y: metaTop - metaBoxHeight + 9, width: contentRight - clientColumnX + 9, height: metaBoxHeight, color: colors.tableBackground, borderColor: colors.border, borderWidth: .8 });
  if (canonicalStructure === "split-addresses") page.drawLine({ start: { x: clientColumnX - 18, y: metaTop + 8 }, end: { x: clientColumnX - 18, y: metaTop - metaBoxHeight + 4 }, thickness: 2, color: colors.primary });
  if (canonicalStructure === "editorial") page.drawRectangle({ x: contentLeft, y: 674, width: 5, height: 42, color: colors.primary });
  page.drawText(referenceLayout ? "Client facturé" : "CLIENT FACTURÉ", { x: clientColumnX, y: metaTop, size: referenceLayout ? 8 : 7, font: referenceLayout ? regular : bold, color: referenceLayout ? colors.text : colors.secondary });
  page.drawText(fit(bold, partyName(client), referenceLayout ? 9 : 10, contentRight - clientColumnX), { x: clientColumnX, y: metaTop - 15, size: referenceLayout ? 9 : 10, font: bold, color: colors.heading });
  const clientAddressLines = limitedLines(regular, address(displayedClientAddress), 8, contentRight - clientColumnX, 3);
  const clientIdentityLines = referenceLayout
    ? [client.siret || client.siren, ...clientAddressLines, client.vat_number && `N° de TVA ${client.vat_number}`].filter(Boolean).map(text)
    : clientAddressLines;
  clientIdentityLines.forEach((line, index) => page.drawText(line, { x: clientColumnX, y: metaTop - 29 - index * 11, size: 8, font: regular, color: referenceLayout ? colors.text : colors.muted }));
  clientContactLines.forEach((line, index) => page.drawText(line, { x: clientColumnX, y: metaTop - 29 - clientIdentityLines.length * 11 - index * 10, size: 8, font: regular, color: colors.muted }));
  y = referenceLayout
    ? Math.min(606, metaTop - 44 - clientIdentityLines.length * 11 - clientContactLines.length * 10)
    : 662 - metaBoxHeight - 10;
  drawColumns();

  let runningSectionSubtotal = 0;
  let renderedLineIndex = 0;
  for (const line of payload.lines || []) {
    const lineType = text(line.line_type || "item");
    if (lineType === "page_break") {
      addPage(true);
      continue;
    }
    const structural = ["title", "subtitle", "section", "text", "comment", "subtotal"].includes(lineType);
    const nameLines = limitedLines(structural ? bold : regular, line.name || line.description || "Designation", structural ? metrics.lineNameSize + 1 : metrics.lineNameSize, 220, structural ? 8 : 5);
    const descriptionLines = structural || !line.description ? [] : limitedLines(regular, line.description, metrics.lineSize - 1, 220, metrics.compact ? 1 : 2);
    const rowHeight = Math.max(metrics.rowPadding, 10 + nameLines.length * 10 + descriptionLines.length * 9);
    if (y - rowHeight < contentBottomLimit) addPage(true);
    if (structural) {
      page.drawRectangle({ x: contentLeft, y: y - rowHeight + 6, width: contentWidth, height: rowHeight, color: colors.tableBackground });
      nameLines.forEach((value, index) => page.drawText(value, { x: contentLeft + 6, y: y - 7 - index * 10, size: metrics.lineNameSize + 1, font: bold, color: colors.heading }));
      if (lineType === "subtotal") {
        const subtotalRight = columnRight.get("total_excl_tax") || columnRight.get("total_incl_tax") || contentRight;
        right(page, bold, amount(Number(line.total_excl_tax) || runningSectionSubtotal, currency), subtotalRight, y - 7, metrics.lineNameSize + 1, colors.heading, 85);
        runningSectionSubtotal = 0;
      }
    } else {
      if (stripedTableRows && renderedLineIndex % 2 === 1) page.drawRectangle({ x: contentLeft, y: y - rowHeight + 4, width: contentWidth, height: rowHeight, color: colors.tableBackground });
      const descriptivePrefix = [visibleColumns.number === true ? `${(payload.lines || []).indexOf(line) + 1}.` : "", visibleColumns.reference === true ? text(line.reference || "") : ""].filter(Boolean).join(" ");
      nameLines.forEach((value, index) => page.drawText(fit(index === 0 ? bold : regular, `${index === 0 && descriptivePrefix ? descriptivePrefix + " " : ""}${value}`, metrics.lineNameSize, descriptionWidth), { x: contentLeft + 6, y: y - 7 - index * 10, size: metrics.lineNameSize, font: index === 0 ? bold : regular, color: colors.text }));
      descriptionLines.forEach((value, index) => page.drawText(fit(regular, value, metrics.lineSize - 1, descriptionWidth), { x: contentLeft + 6, y: y - 7 - nameLines.length * 10 - index * 9, size: metrics.lineSize - 1, font: regular, color: colors.muted }));
      const lineExclTax = Number(line.total_excl_tax ?? ((Number(line.quantity) || 0) * (Number(line.unit_price) || 0))) || 0;
      const lineTax = Number(line.total_tax ?? lineExclTax * (Number(line.tax_rate) || 0) / 100) || 0;
      valueColumns.forEach(column => {
        const key = text(column.key), targetX = columnRight.get(key) || contentRight;
        const value = key === "unit" ? text(line.unit || "")
          : key === "quantity" ? Number(line.quantity || 0).toLocaleString("fr-FR")
          : key === "unit_price" ? amount(line.unit_price, currency)
          : key === "discount" ? `${Number(line.discount_rate || 0).toLocaleString("fr-FR")}%`
          : key === "tax_rate" ? `${Number(line.tax_rate || 0).toLocaleString("fr-FR")}%`
          : key === "total_incl_tax" ? amount(line.total_incl_tax ?? lineExclTax + lineTax, currency)
          : amount(lineExclTax, currency);
        right(page, key.startsWith("total_") ? bold : regular, value, targetX, y - 7, metrics.lineSize, key.startsWith("total_") ? colors.heading : colors.text, numericWidth - 4);
      });
      if (!line.optional) runningSectionSubtotal += Number(line.total_excl_tax ?? ((Number(line.quantity) || 0) * (Number(line.unit_price) || 0))) || 0;
      renderedLineIndex += 1;
    }
    if (visibleTableBorders) page.drawLine({ start: { x: contentLeft, y: y - rowHeight + 4 }, end: { x: contentRight, y: y - rowHeight + 4 }, thickness: 0.5, color: colors.border });
    y -= rowHeight;
  }

  if (y < 330) addPage(false);
  const totalsY = referenceLayout ? Math.min(y - 22, 558) : Math.min(y - 22, 300);
  const vat = new Map<number, { base: number; tax: number }>();
  for (const line of payload.lines || []) {
    if (!["item", "free_item", "discount"].includes(text(line.line_type || "item")) || line.optional) continue;
    const rate = Number(line.tax_rate) || 0;
    const base = Number(line.total_excl_tax ?? ((Number(line.quantity) || 0) * (Number(line.unit_price) || 0))) || 0;
    const tax = Number(line.total_tax ?? base * rate / 100) || 0;
    const current = vat.get(rate) || { base: 0, tax: 0 };
    vat.set(rate, { base: current.base + base, tax: current.tax + tax });
  }
  page.drawText(referenceLayout ? "Détails TVA" : "DETAIL TVA", { x: 42, y: totalsY + 3, size: referenceLayout ? 11 : 7, font: bold, color: colors.heading });
  if (referenceLayout) {
    page.drawText("Taux", { x: 42, y: totalsY - 13, size: 7, font: bold, color: colors.text });
    right(page, bold, "Montant TVA", 205, totalsY - 13, 7, colors.text, 100);
    right(page, bold, "Base HT", 330, totalsY - 13, 7, colors.text, 100);
  }
  if (referenceLayout) page.drawText("Récapitulatif", { x: 354, y: totalsY + 3, size: 11, font: bold, color: colors.heading });
  [...vat.entries()].sort((a, b) => a[0] - b[0]).slice(0, 5).forEach(([rate, values], index) => {
    const rowY = totalsY - (referenceLayout ? 28 : 13) - index * 12;
    page.drawText(`${rate.toLocaleString("fr-FR")} %`, { x: 42, y: rowY, size: 7, font: regular, color: colors.text });
    right(page, regular, referenceLayout ? amount(values.tax, currency) : `Base ${amount(values.base, currency)}`, 205, rowY, 7, referenceLayout ? colors.text : colors.muted, 135);
    right(page, regular, referenceLayout ? amount(values.base, currency) : `TVA ${amount(values.tax, currency)}`, 330, rowY, 7, referenceLayout ? colors.text : colors.muted, 115);
  });
  const showPaymentBalance = doc.document_type !== "quote";
  const totalsBoxHeight = showPaymentBalance ? 115 : (layoutKey === "modern" ? 91 : 83);
  if (!referenceLayout) page.drawRectangle({ x: 354, y: totalsY - totalsBoxHeight + 12, width: 199, height: totalsBoxHeight, color: layoutKey === "modern" ? colors.totals : colors.tableBackground });
  const totalsTextColor = layoutKey === "modern" ? rgb(1, 1, 1) : colors.text;
  if (!referenceLayout) page.drawText("Récapitulatif", { x: 374, y: totalsY + 3, size: 9, font: bold, color: totalsTextColor });
  page.drawText("Total HT", { x: referenceLayout ? 354 : 374, y: totalsY - 14, size: referenceLayout ? 8 : 9, font: bold, color: totalsTextColor });
  right(page, regular, amount(doc.total_excl_tax, currency), 538, totalsY - 14, 9, totalsTextColor);
  page.drawText("Total TVA", { x: referenceLayout ? 354 : 374, y: totalsY - 30, size: referenceLayout ? 8 : 9, font: bold, color: totalsTextColor });
  right(page, regular, amount(doc.total_tax, currency), 538, totalsY - (referenceLayout ? 30 : 34), 9, totalsTextColor);
  const grandTotalColor = layoutKey === "modern" ? rgb(1, 1, 1) : colors.totals;
  if (referenceLayout) page.drawRectangle({ x: 350, y: totalsY - 53, width: 203, height: 17, color: colors.tableBackground });
  else page.drawLine({ start: { x: 370, y: totalsY - 44 }, end: { x: 538, y: totalsY - 44 }, thickness: 1, color: grandTotalColor });
  page.drawText("Total TTC", { x: referenceLayout ? 354 : 374, y: totalsY - (referenceLayout ? 48 : 61), size: referenceLayout ? 8 : 10, font: bold, color: grandTotalColor });
  right(page, bold, amount(doc.total_incl_tax, currency), 538, totalsY - (referenceLayout ? 48 : 61), referenceLayout ? 8 : 10, grandTotalColor);
  if (showPaymentBalance) {
    const paidAmount = Number(doc.amount_paid || doc.paid_amount || 0);
    const remainingAmount = Math.max(0, Number(doc.total_incl_tax || 0) - paidAmount);
    page.drawText("Encaissé", { x: 374, y: totalsY - 79, size: 8, font: regular, color: totalsTextColor });
    right(page, regular, amount(paidAmount, currency), 538, totalsY - 79, 8, totalsTextColor);
    page.drawText("Reste à payer", { x: 374, y: totalsY - 95, size: 8, font: bold, color: grandTotalColor });
    right(page, bold, amount(remainingAmount, currency), 538, totalsY - 95, 8, grandTotalColor);
  }
  const footerLines: string[] = [];
  const footerBody = resolveFooterTokens(templateFooter.body, issuer);
  let legalIdentity = "";
  let legalContact = "";
  if (templateVersion.free_field) footerLines.push(String(templateVersion.free_field));
  if (footerSettings.free_text) footerLines.push(resolveFooterTokens(footerSettings.free_text, issuer));
  if (showLegalMentions) {
    const registeredAddress = [issuer.address_line1 || issuer.address_line_1, issuer.address_line2 || issuer.address_line_2, issuer.postal_code, issuer.city, issuer.country_code].filter(Boolean).map(text).join(" - ");
    legalIdentity = [
      issuer.legal_name || issuer.trade_name,
      issuer.legal_form,
      issuer.social_capital && `Capital ${issuer.social_capital}`,
      registeredAddress,
      issuer.siren && `SIREN ${issuer.siren}`,
      issuer.siret && `SIRET ${issuer.siret}`,
      issuer.ape_code && `APE ${issuer.ape_code}`,
      issuer.rcs_number && `RCS ${issuer.rcs_number}`,
      issuer.registry_court && `Greffe ${issuer.registry_court}`,
      issuer.vat_number && `TVA ${issuer.vat_number}`,
    ].filter(Boolean).map(text).join(" - ");
    legalContact = [issuer.phone_e164 || issuer.phone, issuer.email, issuer.website].filter(Boolean).map(text).join(" - ");
    if (!referenceLayout && legalIdentity) footerLines.push(legalIdentity);
    if (!referenceLayout && legalContact) footerLines.push(legalContact);
    [doc.public_notes, settings.visible_mention, settings.legal_notice].filter(Boolean).forEach(value => footerLines.push(String(value)));
  }
  if (showLatePenalties && settings.collection_fee_notice) footerLines.push(String(settings.collection_fee_notice));
  const footerNote = footerLines.join(" | ");
  limitedLines(regular, footerNote, 6.5, 245, 6).forEach((line, index) => page.drawText(line, { x: 303, y: 175 - index * 8, size: 6.5, font: regular, color: colors.muted }));
  if (showPaymentTerms || acceptsBankTransfer) {
    page.drawText("Conditions de paiement :", { x: 42, y: 175, size: 8, font: bold, color: colors.heading });
    page.drawText(fit(regular, `Délai : ${paymentTermLabel}`, 7, 245), { x: 42, y: 161, size: 7, font: regular, color: colors.text });
    page.drawText(fit(regular, `Mode de paiement : ${paymentMethodLabel}`, 7, 245), { x: 42, y: 149, size: 7, font: regular, color: colors.text });
    if (depositText) page.drawText(fit(regular, depositText, 7, 245), { x: 42, y: 137, size: 7, font: regular, color: colors.text });
  }
  if (acceptsBankTransfer && showBankDetails) drawBankDetails(page, 42, depositText ? 124 : 136, 245);
  if (referenceLayout && doc.document_type === "quote") {
    page.drawText(fit(regular, "Date et signature précédées de la mention « Bon pour accord »", 8, 250), { x: 303, y: 101, size: 8, font: regular, color: colors.text });
  }
  if (referenceLayout && showLegalMentions) {
    limitedLines(regular, [legalIdentity, legalContact].filter(Boolean).join(" - "), 5.5, 245, 2).forEach((line, index) => {
      page.drawText(line, { x: 303, y: 60 - index * 7, size: 5.5, font: regular, color: colors.muted });
    });
  }
  pages.forEach((current, index) => {
    if (footerBody) {
      current.drawLine({ start: { x: 42, y: 46 }, end: { x: 553, y: 46 }, thickness: 0.5, color: colors.border });
      limitedLines(regular, footerBody, 6.5, 500, 2).forEach((line, footerIndex) => centered(current, regular, line, 34 - footerIndex * 8, 6.5, colors.muted, 500));
    }
    if (showPageNumber) {
      const label = `${index + 1} / ${pages.length}`;
      right(current, regular, label, 553, 18, 7, colors.muted);
    }
    if (embeddedFooterLogos.length) {
      let footerLogoX = 42;
      for (const footerLogo of embeddedFooterLogos) {
        const ratio = footerLogo.image.height > 0 ? footerLogo.image.width / footerLogo.image.height : 1;
        const width = footerLogo.width, height = Math.min(22, width / Math.max(.25, ratio));
        current.drawImage(footerLogo.image, { x: footerLogoX, y: 50, width, height });
        footerLogoX += width + 8;
      }
    }
    if (canonicalLinks.length) {
      const annotations = canonicalLinks.map((link, linkIndex) => {
        const url = text(link.url), label = fit(regular, link.label || link.display_text || url, 6.5, 145);
        const x = 42 + linkIndex * 160, y = embeddedFooterLogos.length ? 77 : 49;
        current.drawText(label, { x, y, size: 6.5, font: regular, color: colors.primary });
        return pdf.context.register(pdf.context.obj({
          Type: PDFName.of("Annot"), Subtype: PDFName.of("Link"), Rect: [x, y - 2, x + Math.max(24, regular.widthOfTextAtSize(label, 6.5)), y + 8],
          Border: [0, 0, 0], A: { Type: PDFName.of("Action"), S: PDFName.of("URI"), URI: PDFString.of(url) },
        }));
      });
      current.node.set(PDFName.of("Annots"), pdf.context.obj(annotations));
    }
    if (showPilozBrand) centered(current, regular, "Généré avec Piloz", 18, 6.5, colors.muted, 220);
  });
  pdf.setTitle(`${kind} ${number}`);
  pdf.setAuthor(issuerName);
  pdf.setCreator("PILOZ");
  pdf.setProducer("PILOZ document lifecycle");
  const capturedAt = new Date(payload.captured_at || String(doc.finalized_at || doc.validated_at || doc.updated_at || doc.issue_date || ""));
  const pdfDate = Number.isNaN(capturedAt.valueOf()) ? new Date(0) : capturedAt;
  pdf.setCreationDate(pdfDate);
  pdf.setModificationDate(pdfDate);
  return pdf.save();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PREVIEW_DOCUMENT_TYPES = new Set(["quote", "invoice", "deposit_invoice", "balance_invoice", "credit_note", "proforma_invoice", "recurring_invoice"]);
const MAX_PREVIEW_LINES = 10_000;
const PREVIEW_PAGE_SIZE = 1_000;

type PreviewInput = {
  companyId?: unknown;
  clientId?: unknown;
  templateId?: unknown;
  document?: unknown;
  lines?: unknown;
  contactId?: unknown;
  billingAddressId?: unknown;
  deliveryAddressId?: unknown;
};

function previewFailure(message: string, status: number) {
  return Object.assign(new Error(message), { status });
}

function previewText(value: unknown, maxLength: number) {
  return value == null ? null : String(value).trim().slice(0, maxLength) || null;
}

function previewNumber(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

async function buildPreviewPayload(
  userClient: SupabaseClient<any, "public", "public", any, any>,
  userId: string,
  preview: PreviewInput,
): Promise<{ payload: SnapshotPayload; companyId: string }> {
  const companyId = String(preview.companyId || "");
  if (!UUID.test(companyId)) throw previewFailure("Entreprise invalide", 400);

  const { data: membership, error: membershipError } = await userClient.from("company_members")
    .select("company_id").eq("company_id", companyId).eq("user_id", userId).maybeSingle();
  if (membershipError || !membership) throw previewFailure("Acces refuse a cette entreprise", 403);

  const sourceDocument = record(preview.document);
  const documentType = String(sourceDocument.document_type || "");
  if (!PREVIEW_DOCUMENT_TYPES.has(documentType)) throw previewFailure("Type de document invalide", 400);
  const templateType = documentType === "quote" ? "quote" : "invoice";
  const sourceLines = Array.isArray(preview.lines) ? preview.lines : [];
  if (sourceLines.length > MAX_PREVIEW_LINES) throw previewFailure(`Le document depasse la limite de ${MAX_PREVIEW_LINES} lignes`, 413);

  const [{ data: issuer, error: issuerError }, { data: documentSettings, error: settingsError }] = await Promise.all([
    userClient.from("company_settings").select("*").eq("company_id", companyId).maybeSingle(),
    userClient.from("company_document_settings").select("*").eq("company_id", companyId).maybeSingle(),
  ]);
  if (issuerError || settingsError) throw previewFailure("Parametres du document indisponibles", 503);

  let client: Record<string, unknown> = {};
  const clientId = preview.clientId == null ? "" : String(preview.clientId);
  if (clientId) {
    if (!UUID.test(clientId)) throw previewFailure("Client invalide", 400);
    const { data, error } = await userClient.from("clients").select("*").eq("id", clientId).eq("company_id", companyId).maybeSingle();
    if (error || !data) throw previewFailure("Client introuvable", 404);
    client = record(data);
  }

  const contextId = (explicit: unknown, documentField: string) =>
    String(explicit || sourceDocument[documentField] || "");
  const contactId = contextId(preview.contactId, "contact_id");
  const billingAddressId = contextId(preview.billingAddressId, "billing_address_id");
  const deliveryAddressId = contextId(preview.deliveryAddressId, "delivery_address_id");
  let recipientContact: Record<string, unknown> = {};
  let billingAddress: Record<string, unknown> = {};
  let deliveryAddress: Record<string, unknown> = {};
  if (contactId) {
    if (!UUID.test(contactId) || !clientId) throw previewFailure("Contact destinataire invalide", 400);
    const { data, error } = await userClient.from("client_contacts").select("*")
      .eq("id", contactId).eq("client_id", clientId).eq("company_id", companyId).maybeSingle();
    if (error || !data) throw previewFailure("Contact destinataire introuvable", 404);
    recipientContact = record(data);
  }
  const loadAddress = async (addressId: string, label: string) => {
    if (!addressId) return {};
    if (!UUID.test(addressId) || !clientId) throw previewFailure(`${label} invalide`, 400);
    const { data, error } = await userClient.from("client_addresses").select("*")
      .eq("id", addressId).eq("client_id", clientId).eq("company_id", companyId).maybeSingle();
    if (error || !data) throw previewFailure(`${label} introuvable`, 404);
    return record(data);
  };
  billingAddress = await loadAddress(billingAddressId, "Adresse de facturation");
  deliveryAddress = await loadAddress(deliveryAddressId, "Adresse de livraison");

  const legacyTemplateId = templateType === "quote"
    ? record(documentSettings).default_quote_template_id
    : record(documentSettings).default_invoice_template_id;
  const assignmentType = documentType === "proforma_invoice" ? "invoice" : documentType;
  const { data: assignedTheme } = await userClient.from("document_theme_assignments").select("theme_id")
    .eq("company_id", companyId).eq("document_type", assignmentType).maybeSingle();
  const configuredTemplateId = record(assignedTheme).theme_id || legacyTemplateId;
  const requestedTemplateId = String(preview.templateId || configuredTemplateId || "");
  let template: Record<string, unknown> | null = null;
  if (requestedTemplateId) {
    if (!UUID.test(requestedTemplateId)) throw previewFailure("Modele de document invalide", 400);
    const { data, error } = await userClient.from("document_templates").select("*")
      .eq("id", requestedTemplateId).eq("company_id", companyId).eq("status", "active").maybeSingle();
    if (error || !data) throw previewFailure("Le modele selectionne est introuvable ou inactif", 404);
    template = record(data);
  } else {
    const { data, error } = await userClient.from("document_templates").select("*")
      .eq("company_id", companyId).eq("status", "active")
      .order("is_default", { ascending: false }).order("created_at", { ascending: true }).limit(1).maybeSingle();
    if (error || !data) throw previewFailure("Aucun modele actif pour ce document", 409);
    template = record(data);
  }

  const templateId = String(template.id || "");
  const templateVersion = Number(template.current_version) || 1;
  const { data: versionData, error: versionError } = await userClient.from("document_template_versions").select("*")
    .eq("template_id", templateId).eq("company_id", companyId).eq("version", templateVersion).maybeSingle();
  if (versionError || !versionData) throw previewFailure("La version du modele est introuvable", 409);
  const version = record(versionData);

  let footer: Record<string, unknown> = {};
  const footerId = String(version.footer_id || "");
  if (footerId && UUID.test(footerId)) {
    const { data } = await userClient.from("document_footers").select("*")
      .eq("id", footerId).eq("company_id", companyId).eq("is_active", true).maybeSingle();
    footer = record(data);
  }
  const { data: footerLogoRows } = await userClient.from("document_theme_footer_logos")
    .select("id,name,position,width,document_types,document_theme_assets!inner(storage_path,mime_type,size_bytes)")
    .eq("company_id", companyId).eq("theme_id", templateId).eq("visible", true).order("position");
  const previewDocumentType = documentType || "invoice";
  const themeFooterLogos = (footerLogoRows || []).filter(value => {
    const types = Array.isArray(record(value).document_types) ? record(value).document_types.map(String) : [];
    return !types.length || types.includes(previewDocumentType) || (previewDocumentType !== "quote" && types.includes("invoice"));
  }).map(value => {
    const row = record(value), assetValue = row.document_theme_assets;
    const asset = record(Array.isArray(assetValue) ? assetValue[0] : assetValue);
    return { id: row.id, name: row.name, position: row.position, width: row.width, document_types: row.document_types, ...asset };
  });

  const themeConfiguration = record(version.configuration_json);
  const logoSettings = Object.keys(record(themeConfiguration.logo)).length ? record(themeConfiguration.logo) : record(version.logo_settings);
  let logo: Record<string, unknown> = {};
  const themeLogoId = String(logoSettings.asset_id || "");
  if (logoSettings.enabled !== false && logoSettings.show !== false && UUID.test(themeLogoId)) {
    const { data: themeLogo } = await userClient.from("document_theme_assets").select("storage_path,mime_type,size_bytes,width,height")
      .eq("id", themeLogoId).eq("theme_id", templateId).eq("company_id", companyId).eq("asset_type", "logo").maybeSingle();
    logo = record(themeLogo);
  } else if (logoSettings.enabled !== false && logoSettings.show !== false) {
    const requestedVariant = logoSettings.use_alternate === true ? "dark" : "light";
    const { data: requestedLogo } = await userClient.from("company_logos").select("storage_path,mime_type,size_bytes,width,height,variant")
      .eq("company_id", companyId).eq("variant", requestedVariant).eq("is_active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
    let logoData = requestedLogo;
    if (!logoData && requestedVariant === "dark") {
      const { data: fallbackLogo } = await userClient.from("company_logos").select("storage_path,mime_type,size_bytes,width,height,variant")
        .eq("company_id", companyId).eq("variant", "light").eq("is_active", true).order("created_at", { ascending: false }).limit(1).maybeSingle();
      logoData = fallbackLogo;
    }
    logo = record(logoData);
  }

  const document: Record<string, unknown> = {
    document_type: documentType,
    number: previewText(sourceDocument.number, 80),
    issue_date: previewText(sourceDocument.issue_date, 32),
    due_date: previewText(sourceDocument.due_date, 32),
    validity_date: previewText(sourceDocument.validity_date, 32),
    subject: previewText(sourceDocument.subject, 500),
    currency: previewText(sourceDocument.currency, 3) || "EUR",
    language: previewText(sourceDocument.language, 8) || "fr",
    payment_terms: previewText(sourceDocument.payment_terms, 500),
    payment_method: previewText(sourceDocument.payment_method, 160),
    public_notes: previewText(sourceDocument.public_notes, 4000),
    discount_rate: previewNumber(sourceDocument.discount_rate),
    deposit_rate: previewNumber(sourceDocument.deposit_rate),
    total_excl_tax: previewNumber(sourceDocument.total_excl_tax),
    total_tax: previewNumber(sourceDocument.total_tax),
    total_incl_tax: previewNumber(sourceDocument.total_incl_tax),
    metadata: record(sourceDocument.metadata),
  };
  const lines = sourceLines.map((value, index) => {
    const line = record(value);
    return {
      position: index + 1,
      line_type: previewText(line.line_type, 32) || "item",
      reference: previewText(line.reference, 160),
      name: previewText(line.name, 500),
      description: previewText(line.description, 4000),
      quantity: previewNumber(line.quantity),
      unit: previewText(line.unit, 80),
      unit_price: previewNumber(line.unit_price),
      discount_rate: previewNumber(line.discount_rate),
      tax_rate: previewNumber(line.tax_rate),
      optional: line.optional === true,
      total_excl_tax: previewNumber(line.total_excl_tax),
      total_tax: previewNumber(line.total_tax),
      total_incl_tax: previewNumber(line.total_incl_tax),
    };
  });

  return {
    companyId,
    payload: {
      schema_version: 2,
      captured_at: new Date().toISOString(),
      document,
      lines,
      issuer: record(issuer),
      document_settings: record(documentSettings),
      client,
      recipient_contact: recipientContact,
      billing_address: billingAddress,
      delivery_address: deliveryAddress,
      logo,
      template: { template, version, footer, theme_footer_logos: themeFooterLogos },
    },
  };
}

async function buildSavedDraftPreviewPayload(
  userClient: SupabaseClient<any, "public", "public", any, any>,
  userId: string,
  documentId: string,
): Promise<{ payload: SnapshotPayload; companyId: string }> {
  if (!UUID.test(documentId)) throw previewFailure("Document invalide", 400);
  // Ces tables exposent volontairement des privilèges colonne par colonne.
  // `select("*")` échoue donc dès qu'une colonne interne non lisible est
  // ajoutée, même si le document est parfaitement visible via la RLS.
  const documentColumns = [
    "id", "company_id", "document_type", "number", "status", "client_id", "template_id",
    "contact_id", "billing_address_id", "delivery_address_id",
    "issue_date", "due_date", "validity_date", "subject", "currency", "language",
    "payment_terms", "payment_method", "public_notes", "discount_rate", "deposit_rate",
    "total_excl_tax", "total_tax", "total_incl_tax", "metadata",
  ].join(",");
  const { data: documentData, error: documentError } = await userClient.from("documents")
    .select(documentColumns).eq("id", documentId).maybeSingle();
  if (documentError) throw previewFailure("Le document est temporairement indisponible", 503);
  if (!documentData) throw previewFailure("Document introuvable", 404);
  const document = record(documentData);
  if (String(document.document_type || "") !== "quote" && !["draft", "to_finalize"].includes(String(document.status || "draft"))) {
    throw previewFailure("Ce document n'est plus un brouillon", 409);
  }

  const companyId = String(document.company_id || "");
  const lines: Record<string, unknown>[] = [];
  for (let offset = 0; offset < MAX_PREVIEW_LINES; offset += PREVIEW_PAGE_SIZE) {
    const lineColumns = [
      "id", "company_id", "document_id", "position", "line_type", "reference", "name", "description",
      "quantity", "unit", "unit_price", "discount_rate", "tax_rate", "optional",
      "total_excl_tax", "total_tax", "total_incl_tax",
    ].join(",");
    const { data, error } = await userClient.from("document_lines").select(lineColumns)
      .eq("company_id", companyId).eq("document_id", documentId)
      .order("position", { ascending: true }).order("id", { ascending: true })
      .range(offset, offset + PREVIEW_PAGE_SIZE - 1);
    if (error) throw previewFailure("Les lignes du document sont indisponibles", 503);
    const page = (data || []).map(record);
    lines.push(...page);
    if (page.length < PREVIEW_PAGE_SIZE) break;
  }
  if (lines.length >= MAX_PREVIEW_LINES) {
    const { count, error } = await userClient.from("document_lines").select("id", { count: "exact", head: true })
      .eq("company_id", companyId).eq("document_id", documentId);
    if (error) throw previewFailure("Le nombre de lignes est indisponible", 503);
    if (Number(count) > MAX_PREVIEW_LINES) throw previewFailure(`Le document depasse la limite de ${MAX_PREVIEW_LINES} lignes`, 413);
  }
  return buildPreviewPayload(userClient, userId, {
    companyId,
    clientId: document.client_id,
    templateId: document.template_id,
    contactId: document.contact_id,
    billingAddressId: document.billing_address_id,
    deliveryAddressId: document.delivery_address_id,
    document,
    lines,
  });
}

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
  const companyLogoPath = storagePath.startsWith(`${companyId}/logos/`);
  const themeLogoPath = storagePath.startsWith(`${companyId}/themes/`);
  if ((!companyLogoPath && !themeLogoPath) || storagePath.includes("..")) return undefined;
  try {
    const { data, error } = await userClient.storage.from("company-assets").download(storagePath);
    if (error || !data || data.size > 5 * 1024 * 1024) return undefined;
    return { bytes: new Uint8Array(await data.arrayBuffer()), mimeType: mimeType as LogoAsset["mimeType"] };
  } catch {
    console.warn("[PILOZ PDF] frozen logo unavailable", { code: "logo_download_failed" });
    return undefined;
  }
}

async function loadThemeFooterLogos(
  userClient: SupabaseClient<any, "public", "public", any, any>,
  payload: SnapshotPayload,
  companyId: string,
): Promise<LogoAsset[]> {
  const template = record(payload.template);
  const rows = Array.isArray(template.theme_footer_logos) ? template.theme_footer_logos.map(record) : [];
  const loaded: LogoAsset[] = [];
  for (const row of rows.slice(0, 6)) {
    const storagePath = String(row.storage_path || ""), mimeType = String(row.mime_type || ""), size = Number(row.size_bytes) || 0;
    if (!storagePath.startsWith(`${companyId}/themes/`) || storagePath.includes("..") || !["image/png", "image/jpeg"].includes(mimeType) || size < 1 || size > 5 * 1024 * 1024) continue;
    try {
      const { data, error } = await userClient.storage.from("company-assets").download(storagePath);
      if (!error && data && data.size <= 5 * 1024 * 1024) loaded.push({ bytes: new Uint8Array(await data.arrayBuffer()), mimeType: mimeType as LogoAsset["mimeType"], name: String(row.name || ""), width: Number(row.width || 64) });
    } catch { console.warn("[PILOZ PDF] footer logo unavailable", { code: "footer_logo_download_failed" }); }
  }
  return loaded;
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
  const body = await req.json().catch(() => null) as { documentId?: string; draftDocumentId?: string; preview?: PreviewInput } | null;
  if (!body) return json({ error: "Requete invalide" }, 400);
  if (body.preview || body.draftDocumentId) {
    try {
      if (body.preview && JSON.stringify(body.preview).length > 5_000_000) return json({ error: "Apercu trop volumineux. Enregistrez le brouillon avant de le previsualiser." }, 413);
      const { payload, companyId } = body.draftDocumentId
        ? await buildSavedDraftPreviewPayload(userClient, user.id, body.draftDocumentId)
        : await buildPreviewPayload(userClient, user.id, body.preview || {});
      const logo = await loadFrozenLogo(userClient, payload, companyId);
      const footerLogos = await loadThemeFooterLogos(userClient, payload, companyId);
      const bytes = await buildPdf(payload, logo, footerLogos);
      const responseBody = new Uint8Array(bytes.byteLength);
      responseBody.set(bytes);
      return new Response(responseBody.buffer, {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/pdf",
          "Content-Disposition": 'inline; filename="apercu-document.pdf"',
          "Cache-Control": "no-store, max-age=0",
        },
      });
    } catch (error) {
      const status = Number(record(error).status) || 500;
      console.error("[PILOZ PDF] preview failed", { code: failureCode(error), status, source: body.draftDocumentId ? "saved_draft" : "payload" });
      return json({ error: status >= 500 ? "L'apercu PDF est temporairement indisponible" : error instanceof Error ? error.message : "Apercu invalide" }, status);
    }
  }
  if (!body.documentId || !UUID.test(body.documentId)) return json({ error: "Document invalide" }, 400);

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
    const footerLogos = await loadThemeFooterLogos(userClient, payload, companyId);
    const bytes = await buildPdf(payload, logo, footerLogos);
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
