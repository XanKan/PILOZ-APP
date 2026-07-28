(function (global) {
  'use strict';

  const modern = global.PilozModern;
  if (!modern) return;

  const previousRender = modern.renderRoute;
  const ui = {
    selected: '',
    mode: 'pdf',
    busy: false,
    autoBusy: false,
    decision: '',
    lastAutoSyncAt: 0,
    pdfUrls: new Map(),
    pdfLoading: new Set(),
    xml: new Map(),
    xmlLoading: new Set(),
  };

  const STATUS = {
    received: { label: 'À traiter', tone: 'pending' },
    queued: { label: 'À traiter', tone: 'pending' },
    deposited: { label: 'À traiter', tone: 'pending' },
    'fr:204': { label: 'Prise en charge', tone: 'info' },
    'fr:205': { label: 'Approuvée', tone: 'success' },
    'fr:206': { label: 'Partiellement approuvée', tone: 'warning' },
    'fr:207': { label: 'En litige', tone: 'warning' },
    'fr:208': { label: 'Suspendue', tone: 'muted' },
    'fr:209': { label: 'Traitement terminé', tone: 'success' },
    'fr:210': { label: 'Refusée', tone: 'danger' },
    'fr:211': { label: 'Paiement envoyé', tone: 'info' },
    'fr:212': { label: 'Paiement reçu', tone: 'success' },
    'fr:213': { label: 'Rejetée techniquement', tone: 'danger' },
  };

  const DECISIONS = {
    'fr:206': {
      title: 'Approuver partiellement',
      help: 'Précisez les éléments acceptés et ceux qui restent à corriger.',
      submit: 'Transmettre l’approbation partielle',
    },
    'fr:207': {
      title: 'Mettre la facture en litige',
      help: 'Expliquez le point contesté afin que le fournisseur puisse le traiter.',
      submit: 'Ouvrir le litige',
    },
    'fr:208': {
      title: 'Suspendre le traitement',
      help: 'Indiquez ce qui empêche temporairement le traitement de cette facture.',
      submit: 'Suspendre la facture',
    },
    'fr:210': {
      title: 'Refuser la facture',
      help: 'Le refus est une décision du destinataire. Il ne s’agit pas d’un rejet technique de la PA.',
      submit: 'Confirmer le refus',
    },
  };

  const app = () => global.PilozApp;
  const api = () => global.PilozERP;
  const runtime = () => app()?.getState?.();
  const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[char]));
  const money = (value, currency = 'EUR') => {
    try {
      return new Intl.NumberFormat('fr-FR', { style: 'currency', currency: currency || 'EUR' }).format(Number(value) || 0);
    } catch {
      return `${Number(value || 0).toFixed(2)} €`;
    }
  };
  const date = value => {
    if (!value) return '—';
    const parsed = new Date(String(value).length === 10 ? `${value}T12:00:00` : value);
    return Number.isNaN(parsed.valueOf()) ? '—' : new Intl.DateTimeFormat('fr-FR').format(parsed);
  };
  const datetime = value => {
    if (!value) return '—';
    const parsed = new Date(value);
    return Number.isNaN(parsed.valueOf()) ? '—' : new Intl.DateTimeFormat('fr-FR', {
      dateStyle: 'short', timeStyle: 'short',
    }).format(parsed);
  };
  const notify = message => global.toast?.(message);
  const canReview = () => app()?.allowed?.('purchases.invoices.write') === true
    || app()?.allowed?.('electronic_invoice_manage') === true;
  const canSync = () => app()?.allowed?.('electronic_invoice_manage') === true;

  const invoices = data => (data.documents || [])
    .filter(row => row.document_type === 'purchase_invoice')
    .sort((a, b) => String(b.issue_date || b.created_at).localeCompare(String(a.issue_date || a.created_at)));
  const exchangeFor = (data, id) => (data.superpdpInvoiceExchanges || [])
    .filter(row => row.document_id === id && row.direction === 'incoming')
    .sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')))[0] || null;
  const eventsFor = (data, exchange) => !exchange ? [] : (data.superpdpInvoiceEvents || [])
    .filter(row => row.exchange_id === exchange.id)
    .sort((a, b) => String(b.occurred_at || b.recorded_at || '').localeCompare(String(a.occurred_at || a.recorded_at || '')));
  const supplierFor = (data, id) => (data.suppliers || []).find(row => row.id === id) || null;
  const selectedInvoice = data => {
    const rows = invoices(data);
    if (!rows.some(row => row.id === ui.selected)) ui.selected = rows[0]?.id || '';
    return rows.find(row => row.id === ui.selected) || null;
  };
  const workflowStatus = (data, document) => {
    const exchange = exchangeFor(data, document?.id);
    const event = eventsFor(data, exchange).find(item => /^fr:\d{3}$/.test(String(item.status || '')));
    return String(event?.status || exchange?.status || 'received');
  };
  const statusMeta = code => STATUS[code] || { label: 'Reçue', tone: 'pending' };
  const statusBadge = code => {
    const meta = statusMeta(code);
    return `<span class="superpdp-workflow-badge ${meta.tone}">${esc(meta.label)}</span>`;
  };
  const eventNote = event => {
    const details = Array.isArray(event?.payload?.details) ? event.payload.details : [];
    for (const detail of details) {
      for (const note of Array.isArray(detail?.notes) ? detail.notes : []) {
        for (const content of Array.isArray(note?.contents) ? note.contents : []) {
          if (content?.content) return String(content.content);
        }
      }
    }
    return '';
  };

  async function ensurePdf(data, document) {
    const exchange = exchangeFor(data, document?.id);
    const path = exchange?.pdf_storage_path;
    if (!path || ui.pdfUrls.has(path) || ui.pdfLoading.has(path)) return;
    ui.pdfLoading.add(path);
    try {
      const signed = await api().signedUrl('company-files', path, 900);
      const url = signed?.signedURL || signed?.signedUrl || signed?.url;
      if (url) ui.pdfUrls.set(path, url);
    } catch (error) {
      console.error('[PILOZ SUPER PDP] PDF fournisseur indisponible', { message: error?.message || String(error) });
    } finally {
      ui.pdfLoading.delete(path);
      render(runtime());
    }
  }

  async function ensureXml(data, document) {
    if (!document?.id || ui.xml.has(document.id) || ui.xmlLoading.has(document.id)) return;
    ui.xmlLoading.add(document.id);
    try {
      ui.xml.set(document.id, await api().invoke('platform-connector', {
        action: 'superpdp_document_xml',
        companyId: runtime().companyId,
        documentId: document.id,
      }));
    } catch (error) {
      console.error('[PILOZ SUPER PDP] XML fournisseur indisponible', { message: error?.message || String(error) });
    } finally {
      ui.xmlLoading.delete(document.id);
      render(runtime());
    }
  }

  function preview(data, document) {
    if (!document) return '<main class="superpdp-supplier-preview empty"><b>Aucune facture fournisseur</b><span>Les factures reçues via la PA apparaîtront automatiquement ici.</span></main>';
    const exchange = exchangeFor(data, document.id);
    const pdfPath = exchange?.pdf_storage_path;
    const pdfUrl = pdfPath && ui.pdfUrls.get(pdfPath);
    const xml = ui.xml.get(document.id);
    if (ui.mode === 'pdf' && pdfPath && !pdfUrl && !ui.pdfLoading.has(pdfPath)) setTimeout(() => ensurePdf(data, document), 0);
    if (ui.mode === 'xml' && exchange?.xml_storage_path && !xml && !ui.xmlLoading.has(document.id)) setTimeout(() => ensureXml(data, document), 0);
    const pdf = pdfUrl
      ? `<iframe title="Facture fournisseur ${esc(document.number || '')}" src="${esc(pdfUrl)}#view=FitH&toolbar=0&navpanes=0"></iframe>`
      : `<div class="superpdp-supplier-empty"><b>${exchange ? 'Chargement du PDF électronique…' : 'Aucun PDF SUPER PDP lié'}</b><span>${exchange ? 'Le document apparaîtra automatiquement.' : 'Cette facture a été créée manuellement dans PILOZ.'}</span></div>`;
    const xmlView = xml
      ? `<section class="superpdp-supplier-xml"><header><b>${esc(String(xml.format || 'CII').toUpperCase())}</b><button onclick="PilozSuperPdpWorkspace.downloadXml()">Télécharger</button></header><pre>${esc(xml.xml || '')}</pre></section>`
      : `<div class="superpdp-supplier-empty"><b>${exchange ? 'Chargement du XML électronique…' : 'Aucun XML SUPER PDP lié'}</b><span>${exchange ? 'Le document apparaîtra automatiquement.' : 'Cette facture a été créée manuellement dans PILOZ.'}</span></div>`;
    return `<main class="superpdp-supplier-preview"><nav aria-label="Format de la facture fournisseur"><button class="${ui.mode === 'pdf' ? 'active' : ''}" onclick="PilozSuperPdpWorkspace.setMode('pdf')">PDF</button><button class="${ui.mode === 'xml' ? 'active' : ''}" onclick="PilozSuperPdpWorkspace.setMode('xml')">XML</button></nav>${ui.mode === 'pdf' ? pdf : xmlView}</main>`;
  }

  function list(data, selected) {
    const rows = invoices(data);
    return `<aside class="superpdp-supplier-list"><header><div><h1>Factures fournisseurs</h1><span>${rows.length} document${rows.length > 1 ? 's' : ''}</span></div><button onclick="PilozModern.openSupplierInvoice()">Créer</button></header><div class="superpdp-sandbox-banner"><b>SUPER PDP · bac à sable</b><span>Réception automatique activée. PILOZ reste en production.</span><button ${ui.busy ? 'disabled' : ''} onclick="PilozSuperPdpWorkspace.syncIncoming()">${ui.busy ? 'Synchronisation…' : 'Actualiser maintenant'}</button></div><div class="superpdp-supplier-list-scroll">${rows.map(row => {
      const supplier = supplierFor(data, row.supplier_id);
      const active = row.id === selected?.id;
      const exchange = exchangeFor(data, row.id);
      const code = workflowStatus(data, row);
      return `<button class="${active ? 'active' : ''}" onclick="PilozSuperPdpWorkspace.select('${row.id}')"><span><small>${esc(row.number || row.client_reference || 'Brouillon')}</small><b>${esc(supplier?.legal_name || 'Fournisseur non renseigné')}</b><em>${date(row.issue_date)} · échéance ${date(row.due_date)}</em></span><span><strong>${money(row.total_incl_tax, row.currency)}</strong>${exchange ? statusBadge(code) : `<small>${esc(row.status || 'Brouillon')}</small>`}</span></button>`;
    }).join('') || '<p>Aucune facture fournisseur.</p>'}</div></aside>`;
  }

  function workflowActions(code) {
    if (!canReview()) return '<p class="superpdp-workflow-readonly">Votre rôle permet la consultation, mais pas le traitement de cette facture.</p>';
    if (['fr:209', 'fr:210', 'fr:212', 'fr:213'].includes(code)) return '<p class="superpdp-workflow-readonly">Ce traitement est clôturé. L’historique reste consultable.</p>';
    return `<div class="superpdp-workflow-actions">${!/^fr:/.test(code) ? '<button onclick="PilozSuperPdpWorkspace.sendStatus(\'fr:204\')">Prendre en charge</button>' : ''}<button class="primary" onclick="PilozSuperPdpWorkspace.sendStatus('fr:205')">Approuver</button><button class="danger" onclick="PilozSuperPdpWorkspace.openDecision('fr:210')">Refuser</button><details><summary>Autres décisions</summary><div><button onclick="PilozSuperPdpWorkspace.openDecision('fr:206')">Approuver partiellement</button><button onclick="PilozSuperPdpWorkspace.openDecision('fr:207')">Mettre en litige</button><button onclick="PilozSuperPdpWorkspace.openDecision('fr:208')">Suspendre</button><button onclick="PilozSuperPdpWorkspace.sendStatus('fr:209')">Terminer le traitement</button></div></details></div>`;
  }

  function workflowHistory(data, exchange) {
    const events = eventsFor(data, exchange);
    return `<div class="superpdp-workflow-history"><h4>Historique du traitement</h4>${events.map(event => {
      const code = String(event.status || 'received');
      const meta = statusMeta(code);
      const note = eventNote(event);
      return `<article><i class="${meta.tone}"></i><span><b>${esc(meta.label)}</b><small>${datetime(event.occurred_at || event.recorded_at)}</small>${note ? `<p>${esc(note)}</p>` : ''}</span></article>`;
    }).join('') || '<p>Aucun événement enregistré.</p>'}</div>`;
  }

  function detail(data, document) {
    if (!document) return '<aside class="superpdp-supplier-side"></aside>';
    const supplier = supplierFor(data, document.supplier_id);
    const exchange = exchangeFor(data, document.id);
    const lines = (data.lines || []).filter(row => row.document_id === document.id);
    const code = workflowStatus(data, document);
    return `<aside class="superpdp-supplier-side"><header><small>Facture fournisseur</small><b>${esc(document.number || document.client_reference || 'Brouillon')}</b></header><section><strong>${money(document.total_incl_tax, document.currency)}</strong><span>dont ${money(document.total_tax, document.currency)} de TVA</span><dl><dt>Fournisseur</dt><dd>${esc(supplier?.legal_name || '—')}</dd><dt>Émission</dt><dd>${date(document.issue_date)}</dd><dt>Échéance</dt><dd>${date(document.due_date)}</dd><dt>Statut PILOZ</dt><dd>${esc(document.status || 'Brouillon')}</dd><dt>Lignes</dt><dd>${lines.length}</dd></dl></section>${exchange ? `<section class="superpdp-supplier-workflow"><div class="superpdp-workflow-heading"><div><h3>Traitement de la facture</h3><span>Statut transmis à la PA</span></div>${statusBadge(code)}</div>${workflowActions(code)}<p class="superpdp-workflow-note">Cette décision ne comptabilise pas la facture et n’enregistre aucun paiement.</p>${workflowHistory(data, exchange)}</section><section class="superpdp-supplier-exchange"><h3>Facture électronique</h3><b>Reçue via SUPER PDP · sandbox</b><dl><dt>Format</dt><dd>${esc(exchange.xml_format || 'CII / Factur-X')}</dd><dt>Dernière synchro.</dt><dd>${datetime(exchange.last_synced_at)}</dd></dl><p>Aucune donnée n’a été transmise en production.</p></section>` : ''}</aside>`;
  }

  function modal() {
    const decision = DECISIONS[ui.decision];
    if (!decision) return '';
    return `<div class="superpdp-workflow-modal-backdrop" onclick="if(event.target===this)PilozSuperPdpWorkspace.closeDecision()"><section class="superpdp-workflow-modal" role="dialog" aria-modal="true" aria-labelledby="superpdp-decision-title"><header><div><h2 id="superpdp-decision-title">${esc(decision.title)}</h2><p>${esc(decision.help)}</p></div><button onclick="PilozSuperPdpWorkspace.closeDecision()" aria-label="Fermer">×</button></header><form id="superpdp-decision-form" onsubmit="event.preventDefault();PilozSuperPdpWorkspace.submitDecision()"><label><span>Motif transmis au fournisseur *</span><textarea name="note" required maxlength="1200" placeholder="Expliquez clairement votre décision…"></textarea></label><p>La décision sera horodatée dans PILOZ et envoyée à SUPER PDP en bac à sable.</p><footer><button type="button" onclick="PilozSuperPdpWorkspace.closeDecision()">Annuler</button><button type="submit" class="${ui.decision === 'fr:210' ? 'danger' : 'primary'}" ${ui.busy ? 'disabled' : ''}>${ui.busy ? 'Transmission…' : esc(decision.submit)}</button></footer></form></section></div>`;
  }

  function scheduleAutoSync() {
    if (!canSync() || ui.busy || ui.autoBusy || Date.now() - ui.lastAutoSyncAt < 120000) return;
    ui.lastAutoSyncAt = Date.now();
    setTimeout(() => syncIncoming(true), 0);
  }

  function render(runtimeState) {
    const current = runtimeState || runtime();
    const data = current?.data || {};
    const document = selectedInvoice(data);
    const main = documentElement();
    if (!main) return true;
    main.innerHTML = `<section class="superpdp-supplier-workspace">${list(data, document)}${preview(data, document)}${detail(data, document)}</section>${modal()}`;
    scheduleAutoSync();
    return true;
  }

  function documentElement() {
    return global.document.getElementById('main');
  }

  function select(id) {
    ui.selected = id;
    ui.mode = 'pdf';
    ui.decision = '';
    render(runtime());
  }

  function setMode(mode) {
    ui.mode = mode === 'xml' ? 'xml' : 'pdf';
    render(runtime());
  }

  function openDecision(statusCode) {
    if (!DECISIONS[statusCode] || !canReview()) return;
    ui.decision = statusCode;
    render(runtime());
    setTimeout(() => global.document.querySelector('#superpdp-decision-form textarea')?.focus(), 0);
  }

  function closeDecision() {
    if (ui.busy) return;
    ui.decision = '';
    render(runtime());
  }

  async function sendStatus(statusCode, note = '') {
    const current = runtime();
    const document = selectedInvoice(current?.data || {});
    if (!document || ui.busy || !canReview()) return;
    ui.busy = true;
    render(current);
    try {
      const result = await api().invoke('platform-connector', {
        action: 'superpdp_create_invoice_event',
        companyId: current.companyId,
        documentId: document.id,
        statusCode,
        note,
      });
      ui.decision = '';
      await app().refresh();
      notify(`Décision transmise : ${statusMeta(result.status || statusCode).label}.`);
    } catch (error) {
      console.error('[PILOZ SUPER PDP] décision fournisseur impossible', {
        code: error?.code || '', status: error?.status || 0, message: error?.message || String(error),
      });
      notify(error?.message || 'La décision n’a pas pu être transmise.');
    } finally {
      ui.busy = false;
      render(runtime());
    }
  }

  function submitDecision() {
    const form = global.document.getElementById('superpdp-decision-form');
    if (!form?.reportValidity()) return;
    const note = String(new FormData(form).get('note') || '').trim();
    if (!note) return;
    sendStatus(ui.decision, note);
  }

  async function syncIncoming(silent = false) {
    if (ui.busy || ui.autoBusy) return;
    if (silent) ui.autoBusy = true;
    else {
      ui.busy = true;
      render(runtime());
    }
    try {
      const result = await api().invoke('platform-connector', {
        action: 'superpdp_sync_incoming',
        companyId: runtime().companyId,
      });
      await app().refresh();
      if (!silent) {
        const imported = Number(result.imported || 0);
        const failed = Number(result.failed || 0);
        const found = Number(result.found || 0);
        if (failed) notify(`${imported} facture(s) importée(s). ${failed} facture(s) reçue(s) n’ont pas pu être intégrées.`);
        else if (!found) notify('Synchronisation terminée : aucune nouvelle facture reçue dans le bac à sable SUPER PDP.');
        else notify(`${imported} nouvelle(s) facture(s) fournisseur importée(s). Les statuts ont été actualisés.`);
      }
    } catch (error) {
      console.error('[PILOZ SUPER PDP] synchronisation fournisseur impossible', {
        code: error?.code || '', status: error?.status || 0, message: error?.message || String(error),
      });
      if (!silent) notify(error?.message || 'La synchronisation SUPER PDP a échoué.');
    } finally {
      ui.busy = false;
      ui.autoBusy = false;
      render(runtime());
    }
  }

  function downloadXml() {
    const document = selectedInvoice(runtime().data);
    const payload = document && ui.xml.get(document.id);
    if (!payload?.xml) return;
    const blob = new Blob([payload.xml], { type: 'application/xml;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const anchor = global.document.createElement('a');
    anchor.href = url;
    anchor.download = `${document.number || 'facture-fournisseur'}-${payload.format || 'cii'}.xml`;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function renderRoute(route, runtimeState) {
    if (route === 'purchase-invoices') return render(runtimeState);
    return previousRender?.(route, runtimeState) || false;
  }

  Object.assign(modern, { renderRoute });
  global.PilozSuperPdpWorkspace = {
    render,
    select,
    setMode,
    syncIncoming,
    sendStatus,
    openDecision,
    closeDecision,
    submitDecision,
    downloadXml,
  };
})(window);
