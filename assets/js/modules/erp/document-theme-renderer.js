(function (global) {
  'use strict';

  const VERSION = 'theme-renderer-v1';
  const TYPES = [
    ['quote', 'Devis'], ['invoice', 'Factures'], ['deposit_invoice', "Factures d’acompte"],
    ['balance_invoice', 'Factures de solde'], ['progress_invoice', 'Factures de situation'],
    ['credit_note', 'Avoirs'], ['sales_order', 'Bons de commande'], ['purchase_order', 'Commandes fournisseurs']
  ];
  const STRUCTURES = [
    ['classic-balanced', 'Classique équilibré'], ['compact-header', 'En-tête compact'],
    ['split-addresses', 'Adresses en colonnes'], ['boxed-client', 'Client encadré'],
    ['editorial', 'Éditorial'], ['modern-color', 'Moderne coloré']
  ];
  const COLUMNS = [
    ['number', '#', true], ['reference', 'Référence', false], ['description', 'Désignation et description', true],
    ['unit', 'Unité', true], ['quantity', 'Quantité', true], ['unit_price', 'Prix unitaire HT', true],
    ['discount', 'Remise', false], ['tax_rate', 'TVA', false], ['total_excl_tax', 'Montant HT', true],
    ['total_incl_tax', 'Montant TTC', false]
  ];
  const FONTS = ['Helvetica', 'Arial', 'Verdana', 'Georgia', 'Times New Roman', 'Trebuchet MS', 'Courier New'];
  const PALETTES = [
    ['#11BFAE', '#13294B', '#FFFFFF', '#172038'], ['#2563EB', '#172554', '#FFFFFF', '#1E293B'],
    ['#7C3AED', '#211A4A', '#FFFFFF', '#28213F'], ['#0F9F8F', '#164E46', '#FFFFFF', '#173B36'],
    ['#65A30D', '#29450B', '#FFFFFF', '#263517'], ['#E26D2F', '#5A2A12', '#FFFDFC', '#3E2418']
  ];
  const DECORATIONS = ['none', 'waves', 'corner', 'ribbon', 'dots', 'lines', 'blocks', 'orbit', 'chevrons', 'frame', 'arc', 'custom'];

  const clone = value => JSON.parse(JSON.stringify(value));
  const esc = value => String(value == null ? '' : value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
  const color = (value, fallback) => /^#[0-9a-f]{6}$/i.test(String(value || '')) ? String(value) : fallback;
  const safeUrl = value => /^https?:\/\//i.test(String(value || '')) ? String(value) : '';
  const money = value => new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' }).format(Number(value || 0));

  function defaults(structureKey = 'classic-balanced') {
    return {
      schema_version: 1, renderer_version: VERSION,
      structure: { key: STRUCTURES.some(row => row[0] === structureKey) ? structureKey : 'classic-balanced' },
      logo: { enabled: true, asset_id: null, storage_path: null, signed_url: null, width: 128, alignment: 'left', preserve_ratio: true },
      colors: { primary: '#11BFAE', secondary: '#13294B', background: '#FFFFFF', text: '#172038', muted: '#64748B', border: '#DCE4EE' },
      typography: {
        title: { family: 'Helvetica', size: 'normal' }, content: { family: 'Helvetica', size: 'normal' },
        table: { family: 'Helvetica', size: 'normal' }
      },
      table: { striped: false, borders: true, colored_header: true, radius: 2, columns: COLUMNS.map((row, index) => ({ key: row[0], label: row[1], visible: row[2], locked: row[0] === 'description', position: index + 1 })) },
      decoration: { kind: 'none', asset_id: null, signed_url: null, opacity: .12, position: 'all', repeat: false },
      footer: { show_piloz_brand: false, free_text: '', show_legal: true, show_contact: true, show_bank_details: true, show_page_number: true, logo_ids: [] },
      spacing: { top: 36, bottom: 48, left: 36, right: 36, link_vertical: false, link_horizontal: false },
      links: [], assignments: []
    };
  }

  function mergeObject(base, incoming) {
    const result = { ...base };
    Object.entries(incoming && typeof incoming === 'object' && !Array.isArray(incoming) ? incoming : {}).forEach(([key, value]) => {
      if (value && typeof value === 'object' && !Array.isArray(value) && base[key] && typeof base[key] === 'object' && !Array.isArray(base[key])) result[key] = mergeObject(base[key], value);
      else result[key] = value;
    });
    return result;
  }

  function normalize(input) {
    const source = input && typeof input === 'object' ? input : {};
    const result = mergeObject(defaults(source?.structure?.key), source);
    result.schema_version = 1;
    result.renderer_version = VERSION;
    result.colors = {
      primary: color(result.colors.primary, '#11BFAE'), secondary: color(result.colors.secondary, '#13294B'),
      background: color(result.colors.background, '#FFFFFF'), text: color(result.colors.text, '#172038'),
      muted: color(result.colors.muted, '#64748B'), border: color(result.colors.border, '#DCE4EE')
    };
    result.structure.key = STRUCTURES.some(row => row[0] === result.structure.key) ? result.structure.key : 'classic-balanced';
    ['title', 'content', 'table'].forEach(key => {
      result.typography[key].family = FONTS.includes(result.typography[key].family) ? result.typography[key].family : 'Helvetica';
      result.typography[key].size = ['small', 'normal', 'large'].includes(result.typography[key].size) ? result.typography[key].size : 'normal';
    });
    const supplied = Array.isArray(result.table.columns) ? result.table.columns : [];
    result.table.columns = COLUMNS.map((definition, index) => {
      const existing = supplied.find(column => column.key === definition[0]) || {};
      return { key: definition[0], label: String(existing.label || definition[1]), visible: definition[0] === 'description' ? true : existing.visible !== false && (existing.visible === true || definition[2]), locked: definition[0] === 'description', position: Number(existing.position || index + 1) };
    }).sort((a, b) => a.position - b.position).map((column, index) => ({ ...column, position: index + 1 }));
    result.links = (Array.isArray(result.links) ? result.links : []).filter(link => safeUrl(link.url)).slice(0, 12);
    result.assignments = (Array.isArray(result.assignments) ? result.assignments : []).filter(type => TYPES.some(row => row[0] === type));
    ['top', 'bottom', 'left', 'right'].forEach(key => result.spacing[key] = Math.max(12, Math.min(120, Number(result.spacing[key] || defaults().spacing[key]))));
    return result;
  }

  function sample(documentType = 'invoice') {
    const labels = Object.fromEntries(TYPES);
    return {
      document: { type: documentType, title: labels[documentType] || 'Document', number: 'SPECIMEN', issue_date: '25/07/2026', due_date: '24/08/2026', status: 'Brouillon', total_excl_tax: 212.45, tax_amount: 42.49, total_incl_tax: 254.94 },
      issuer: { name: 'PILOZ EI', contact: 'Équipe Piloz', email: 'contact@piloz.fr', phone: '+33 3 00 00 00 00', address: '223 avenue du Général Leclerc\n54000 Nancy · France', siret: 'SIRET 000 000 000 00000' },
      client: { name: 'Client exemple', contact: 'Camille Martin', email: 'camille@example.fr', address: '8 rue des Lilas\n75008 Paris · France' },
      lines: [
        { reference: 'TEST-01', description: "Jus d’orange", detail: 'Produit de démonstration', unit: 'unité', quantity: 1, unit_price: 2.45, discount: 0, tax_rate: 20, total_excl_tax: 2.45, total_incl_tax: 2.94 },
        { reference: 'TEST-02', description: 'Réparation ordinateur', detail: 'Prestation de service', unit: 'heure', quantity: 1, unit_price: 90, discount: 0, tax_rate: 20, total_excl_tax: 90, total_incl_tax: 108 },
        { reference: 'TEST-03', description: 'Développement de site web', detail: 'Prestation de service', unit: 'heure', quantity: 1, unit_price: 95, discount: 0, tax_rate: 20, total_excl_tax: 95, total_incl_tax: 114 },
        { reference: 'TEST-04', description: 'Bijou en ébène', detail: '', unit: 'article', quantity: 1, unit_price: 24.99, discount: 0, tax_rate: 20, total_excl_tax: 24.99, total_incl_tax: 29.99 }
      ],
      payment: { terms: '30 jours', method: 'Virement', iban: 'FR76 0000 0000 0000 0000 0000 000', bic: 'PILOZFRPP' },
      legal: 'TVA applicable selon la réglementation en vigueur.'
    };
  }

  function sizeClass(size) { return size === 'small' ? '.88' : size === 'large' ? '1.12' : '1'; }
  function renderDecoration(config) {
    const decoration = config.decoration || {};
    if (decoration.kind === 'none') return '';
    if (decoration.kind === 'custom' && safeUrl(decoration.signed_url)) return `<img class="dtr-decoration custom" src="${esc(decoration.signed_url)}" alt="" style="opacity:${Number(decoration.opacity || .12)}">`;
    return `<div class="dtr-decoration dtr-decoration-${esc(decoration.kind)}" style="opacity:${Number(decoration.opacity || .12)}"></div>`;
  }
  function logoHtml(config, data) {
    if (!config.logo.enabled) return '';
    const url = safeUrl(config.logo.signed_url || data?.logo?.signed_url);
    if (!url) return `<div class="dtr-logo-placeholder" style="width:${Number(config.logo.width)}px">LOGO</div>`;
    return `<img class="dtr-logo" src="${esc(url)}" alt="Logo" style="width:${Number(config.logo.width)}px">`;
  }
  function colValue(line, key, index) {
    if (key === 'number') return index + 1;
    if (key === 'description') return `<strong>${esc(line.description)}</strong>${line.reference ? `<small>${esc(line.reference)}</small>` : ''}${line.detail ? `<em>${esc(line.detail)}</em>` : ''}`;
    if (key === 'quantity') return esc(line.quantity);
    if (key === 'unit_price' || key === 'total_excl_tax' || key === 'total_incl_tax') return money(line[key]);
    if (key === 'discount' || key === 'tax_rate') return `${Number(line[key] || 0)} %`;
    return esc(line[key]);
  }

  function render(inputConfig, inputData, options = {}) {
    const config = normalize(inputConfig), data = inputData || sample(options.documentType), columns = config.table.columns.filter(column => column.visible);
    const structure = config.structure.key, specimen = options.specimen !== false;
    const links = config.links.map(link => `<a href="${esc(link.url)}" target="_blank" rel="noopener noreferrer">${esc(link.label || link.display_text || link.url)}</a>`).join(' · ');
    const footerLogos = (Array.isArray(data.footer_logos) ? data.footer_logos : []).filter(logo => safeUrl(logo.signed_url)).map(logo => `<img src="${esc(logo.signed_url)}" alt="${esc(logo.name || 'Logo de certification')}" style="width:${Math.max(24, Math.min(140, Number(logo.width || 64)))}px">`).join('');
    const style = `--dtr-primary:${config.colors.primary};--dtr-secondary:${config.colors.secondary};--dtr-bg:${config.colors.background};--dtr-text:${config.colors.text};--dtr-muted:${config.colors.muted};--dtr-border:${config.colors.border};--dtr-pad-t:${config.spacing.top}px;--dtr-pad-b:${config.spacing.bottom}px;--dtr-pad-l:${config.spacing.left}px;--dtr-pad-r:${config.spacing.right}px;--dtr-title-font:${esc(config.typography.title.family)};--dtr-content-font:${esc(config.typography.content.family)};--dtr-table-font:${esc(config.typography.table.family)};--dtr-title-scale:${sizeClass(config.typography.title.size)};--dtr-content-scale:${sizeClass(config.typography.content.size)};--dtr-table-scale:${sizeClass(config.typography.table.size)};--dtr-radius:${Number(config.table.radius || 0)}px`;
    return `<article class="dtr-page dtr-${esc(structure)} ${config.table.striped ? 'is-striped' : ''} ${config.table.borders ? 'has-borders' : ''} ${config.table.colored_header ? 'has-colored-head' : ''}" style="${style}">
      ${renderDecoration(config)}${specimen ? '<div class="dtr-specimen" aria-hidden="true">SPECIMEN</div>' : ''}
      <header class="dtr-header"><div class="dtr-logo-wrap align-${esc(config.logo.alignment || 'left')}">${logoHtml(config, data)}</div><div class="dtr-document-heading"><h1>${esc(data.document.title)}</h1><div class="dtr-provisional">Document provisoire <span>${esc(data.document.status || 'Brouillon')}</span></div></div></header>
      <section class="dtr-parties"><div class="dtr-issuer"><strong>${esc(data.issuer.name)}</strong><span>${esc(data.issuer.contact)}</span><span>${esc(data.issuer.email)}</span><span>${esc(data.issuer.phone)}</span><span>${esc(data.issuer.address).replace(/\n/g, '<br>')}</span><span>${esc(data.issuer.siret)}</span></div><div class="dtr-client"><small>Destinataire</small><strong>${esc(data.client.name)}</strong><span>${esc(data.client.contact)}</span><span>${esc(data.client.email)}</span><span>${esc(data.client.address).replace(/\n/g, '<br>')}</span></div></section>
      <section class="dtr-meta"><div><b>Numéro</b><span>${esc(data.document.number)}</span></div><div><b>Date d’émission</b><span>${esc(data.document.issue_date)}</span></div><div><b>Date d’exigibilité du paiement</b><span>${esc(data.document.due_date)}</span></div></section>
      <table class="dtr-table"><thead><tr>${columns.map(column => `<th data-column="${esc(column.key)}">${esc(column.label)}</th>`).join('')}</tr></thead><tbody>${data.lines.map((line, index) => `<tr>${columns.map(column => `<td data-column="${esc(column.key)}">${colValue(line, column.key, index)}</td>`).join('')}</tr>`).join('')}</tbody></table>
      <section class="dtr-summary"><div class="dtr-payment"><h2>Conditions de paiement</h2><b>Délai de paiement</b><span>${esc(data.payment.terms)}</span><b>Moyen de paiement</b><span>${esc(data.payment.method)}</span>${config.footer.show_bank_details ? `<div class="dtr-bank"><b>Coordonnées bancaires</b><span>IBAN : ${esc(data.payment.iban)}</span><span>BIC : ${esc(data.payment.bic)}</span></div>` : ''}</div><div class="dtr-totals"><div><span>Total HT</span><strong>${money(data.document.total_excl_tax)}</strong></div><div><span>TVA</span><strong>${money(data.document.tax_amount)}</strong></div><div class="grand"><span>Total TTC</span><strong>${money(data.document.total_incl_tax)}</strong></div><small>${esc(data.legal)}</small></div></section>
      <footer class="dtr-footer">${footerLogos ? `<div class="dtr-footer-logos">${footerLogos}</div>` : ''}${config.footer.free_text ? `<div>${esc(config.footer.free_text).replace(/\n/g, '<br>')}</div>` : ''}${config.footer.show_contact ? `<div>${esc(data.issuer.email)} · ${esc(data.issuer.phone)}</div>` : ''}${links ? `<div class="dtr-links">${links}</div>` : ''}${config.footer.show_piloz_brand ? '<div>Généré avec Piloz</div>' : ''}${config.footer.show_page_number ? '<div class="dtr-page-number">Page 1 / 1</div>' : ''}</footer>
    </article>`;
  }

  global.PilozDocumentThemeRenderer = { VERSION, TYPES, STRUCTURES, COLUMNS, FONTS, PALETTES, DECORATIONS, defaults, normalize, sample, render, clone, esc, safeUrl };
})(window);
