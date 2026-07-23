(function (global) {
  "use strict";
  const api = () => global.PilozERP,
    app = () => global.PilozApp;
  const esc = (value) =>
    global.PilozCommercialV2?.esc?.(value) ??
    String(value ?? "").replace(
      /[&<>"']/g,
      (char) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[char],
    );
  const money = (value, currency = "EUR") =>
    new Intl.NumberFormat("fr-FR", {
      style: "currency",
      currency: currency || "EUR",
    }).format(Number(value) || 0);
  const date = (value) =>
    value ? new Intl.DateTimeFormat("fr-FR").format(new Date(value)) : "—";
  const datetime = (value) =>
    value
      ? new Intl.DateTimeFormat("fr-FR", {
          dateStyle: "medium",
          timeStyle: "short",
        }).format(new Date(value))
      : "—";
  const notify = (message, kind = "info") =>
    global.PilozCommercialV2?.notify?.(message, kind) ||
    global.toast?.(message);
  const button = (label, handler, kind = "btn-o", attrs = "") =>
    `<button ${/\btype\s*=/.test(attrs) ? "" : 'type="button"'} class="btn ${kind}" onclick="${handler}" ${attrs}>${esc(label)}</button>`;
  const clientName = (row) =>
    row?.legal_name ||
    row?.trade_name ||
    [row?.first_name, row?.last_name].filter(Boolean).join(" ") ||
    "Client sans nom";
  const memberName = (state, id) =>
    !id
      ? "Non attribué"
      : id === global.PilozRuntime?.session?.user_id
        ? "Moi"
        : (state.data.members || []).find((x) => x.user_id === id)
            ?.display_name || id.slice(0, 8);
  const statusLabels = {
    active: "Actif",
    prospect: "Prospect",
    watch: "À surveiller",
    inactive: "Inactif",
    archived: "Archivé",
  };
  const roleLabels = {
    primary: "Contact principal",
    commercial: "Contact commercial",
    billing: "Contact facturation",
    accounting: "Contact comptabilité",
    delivery: "Contact livraison",
    signatory: "Signataire",
    decision_maker: "Décideur",
    technical: "Contact technique",
    other: "Autre",
  };
  const addressLabels = {
    registered: "Siège social",
    main: "Adresse principale",
    billing: "Facturation",
    shipping: "Livraison",
    service: "Intervention",
    secondary: "Établissement secondaire",
    other: "Autre",
  };
  const tabs = [
    ["summary", "Synthèse"],
    ["coordinates", "Coordonnées"],
    ["contacts", "Contacts"],
    ["addresses", "Adresses"],
    ["quotes", "Devis"],
    ["invoices", "Factures"],
    ["payments", "Paiements"],
    ["schedules", "Échéances"],
    ["activities", "Activités"],
    ["accounting", "Comptabilité"],
    ["documents", "Documents"],
    ["notes", "Notes"],
    ["history", "Historique"],
  ];
  const defaultColumns = [
    "select",
    "client",
    "type",
    "contact",
    "email",
    "phone",
    "city",
    "account",
    "owner",
    "invoiced",
    "paid",
    "outstanding",
    "last_document",
    "status",
    "actions",
  ];
  const columnLabels = {
    client: "Client",
    type: "Type",
    contact: "Contact principal",
    email: "E-mail",
    phone: "Téléphone",
    city: "Ville",
    account: "Compte auxiliaire",
    owner: "Responsable",
    invoiced: "Total facturé",
    paid: "Total encaissé",
    outstanding: "Reste à payer",
    last_document: "Dernier document",
    status: "Statut",
    actions: "Actions",
  };
  const ui = {
    search: "",
    status: "",
    kind: "",
    owner: "",
    tag: "",
    overdue: false,
    inactiveDays: "",
    debtor: false,
    sort: "name",
    direction: "asc",
    page: 0,
    pageSize: 50,
    selected: new Set(),
    columns: loadColumns(),
    directory: null,
    directoryKey: "",
    directoryLoading: false,
    directoryError: "",
    detail: new Map(),
    timers: new Map(),
    busy: false,
    advanced: false,
  };
  let currentState = null,
    saveWrapped = false,
    lastDocumentClient = "";

  function loadColumns() {
    try {
      const saved = JSON.parse(
        localStorage.getItem("piloz.client.columns") || "null",
      );
      return Array.isArray(saved) && saved.length
        ? saved
        : defaultColumns.slice();
    } catch {
      return defaultColumns.slice();
    }
  }
  function rawRoute() {
    return (location.hash || "").slice(1);
  }
  function routeParts(raw = rawRoute()) {
    const [path, query = ""] = raw.split("?");
    return { path, query: new URLSearchParams(query) };
  }
  function isUuid(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value || "",
    );
  }
  function statusBadge(value) {
    const tone =
      value === "active"
        ? "success"
        : value === "watch"
          ? "warning"
          : value === "archived" || value === "inactive"
            ? "neutral"
            : "info";
    return `<span class="modern-status ${tone}">${esc(statusLabels[value] || value || "Actif")}</span>`;
  }
  function empty(title, text, action = "") {
    return `<div class="client-empty"><span aria-hidden="true">○</span><b>${esc(title)}</b><p>${esc(text)}</p>${action}</div>`;
  }
  function skeleton(rows = 5) {
    return `<div class="client-skeleton">${Array.from({ length: rows }, () => "<i></i>").join("")}</div>`;
  }
  function openDrawer(title, content, wide = false) {
    let node = document.getElementById("client-workspace-drawer");
    if (!node) {
      node = document.createElement("div");
      node.id = "client-workspace-drawer";
      document.body.appendChild(node);
    }
    node.className = `client-drawer-shell open ${wide ? "wide" : ""}`;
    node.innerHTML = `<div class="client-drawer-backdrop" onclick="PilozClients.closeDrawer()"></div><aside class="client-drawer" role="dialog" aria-modal="true"><header><div><small>Espace Clients</small><h2>${esc(title)}</h2></div><button type="button" aria-label="Fermer" onclick="PilozClients.closeDrawer()">×</button></header><div class="client-drawer-body">${content}</div></aside>`;
  }
  function closeDrawer() {
    document.getElementById("client-workspace-drawer")?.remove();
  }
  function formData(id) {
    const form = document.getElementById(id);
    return form ? Object.fromEntries(new FormData(form)) : {};
  }
  function setBusy(value, selector = "[data-client-save]") {
    ui.busy = value;
    document.querySelectorAll(selector).forEach((node) => {
      node.disabled = value;
      node.setAttribute("aria-busy", String(value));
    });
  }
  function queryPath(table, parts) {
    return api().query(table, parts.join("&"));
  }
  function schemaMissing(error) {
    return /PGRST|schema cache|does not exist|not found/i.test(
      [error?.code, error?.message].join(" "),
    );
  }

  function directoryKey() {
    return JSON.stringify([
      ui.search,
      ui.status,
      ui.kind,
      ui.owner,
      ui.tag,
      ui.overdue,
      ui.inactiveDays,
      ui.debtor,
      ui.sort,
      ui.direction,
      ui.page,
      ui.pageSize,
    ]);
  }
  function fallbackDirectory(state) {
    const paidByDoc = new Map(),
      docs = state.data.documents || [];
    (state.data.payments || [])
      .filter((x) => x.status === "confirmed")
      .forEach((x) =>
        paidByDoc.set(
          x.document_id,
          (paidByDoc.get(x.document_id) || 0) + Number(x.amount),
        ),
      );
    let rows = (state.data.clients || []).map((client) => {
      const clientDocs = docs.filter((x) => x.client_id === client.id),
        invoiced = clientDocs
          .filter(
            (x) =>
              [
                "invoice",
                "deposit_invoice",
                "balance_invoice",
                "credit_note",
              ].includes(x.document_type) && x.finalized_at,
          )
          .reduce(
            (sum, x) =>
              sum +
              (x.document_type === "credit_note" ? -1 : 1) *
                Number(x.total_incl_tax),
            0,
          ),
        paid = clientDocs.reduce(
          (sum, x) => sum + (paidByDoc.get(x.id) || 0),
          0,
        ),
        contact = (state.data.clientContacts || [])
          .filter((x) => x.client_id === client.id)
          .sort((a, b) => Number(b.is_primary) - Number(a.is_primary))[0],
        account = (state.data.clientAccounting || []).find(
          (x) => x.client_id === client.id,
        ),
        lastActivity =
          (state.data.activities || [])
            .filter((x) => x.client_id === client.id)
            .map((x) => x.updated_at || x.created_at)
            .sort()
            .pop() || null;
      return {
        ...client,
        contact_first_name: contact?.first_name,
        contact_last_name: contact?.last_name,
        contact_email: contact?.email,
        contact_phone: contact?.phone_e164,
        auxiliary_account: account?.auxiliary_account || "",
        total_invoiced: invoiced,
        total_paid: paid,
        outstanding: Math.max(0, invoiced - paid),
        last_document_at:
          clientDocs
            .map((x) => x.updated_at)
            .sort()
            .pop() || null,
        last_activity_at: lastActivity,
        overdue_count: clientDocs.filter(
          (x) =>
            x.due_date &&
            x.due_date < new Date().toISOString().slice(0, 10) &&
            !["paid", "cancelled"].includes(x.status),
        ).length,
      };
    });
    const q = ui.search.trim().toLocaleLowerCase("fr");
    if (q)
      rows = rows.filter((x) =>
        Object.values(x).join(" ").toLocaleLowerCase("fr").includes(q),
      );
    if (ui.status)
      rows = rows.filter((x) => (x.customer_status || "active") === ui.status);
    if (ui.kind) rows = rows.filter((x) => x.kind === ui.kind);
    if (ui.owner) rows = rows.filter((x) => x.assigned_user_id === ui.owner);
    if (ui.tag)
      rows = rows.filter((x) =>
        (x.tags || []).some((tag) =>
          tag.toLocaleLowerCase("fr").includes(ui.tag.toLocaleLowerCase("fr")),
        ),
      );
    if (ui.overdue) rows = rows.filter((x) => Number(x.overdue_count) > 0);
    if (ui.debtor) rows = rows.filter((x) => Number(x.outstanding) > 0);
    if (ui.inactiveDays !== "") {
      const limit = Date.now() - Number(ui.inactiveDays) * 86400000;
      rows = rows.filter(
        (x) =>
          !x.last_activity_at || new Date(x.last_activity_at).getTime() < limit,
      );
    }
    const field =
        {
          name: "legal_name",
          invoiced: "total_invoiced",
          paid: "total_paid",
          outstanding: "outstanding",
          last_document: "last_document_at",
          last_activity: "last_activity_at",
        }[ui.sort] || "legal_name",
      factor = ui.direction === "desc" ? -1 : 1;
    rows.sort(
      (a, b) =>
        factor *
        String(a[field] ?? "").localeCompare(String(b[field] ?? ""), "fr", {
          numeric: true,
        }),
    );
    return {
      items: rows.slice(ui.page * ui.pageSize, (ui.page + 1) * ui.pageSize),
      total: rows.length,
    };
  }
  async function loadDirectory(state) {
    const key = directoryKey();
    if (ui.directoryLoading) return;
    ui.directoryLoading = true;
    ui.directoryError = "";
    try {
      let result;
      try {
        result = await api().rpc("get_client_directory_v2", {
          target_company_id: state.companyId,
          target_search: ui.search || null,
          target_filters: {
            status: ui.status || null,
            kind: ui.kind || null,
            assigned_user_id: ui.owner || null,
            tag: ui.tag || null,
            overdue: ui.overdue,
            inactive_days:
              ui.inactiveDays === "" ? null : Number(ui.inactiveDays),
            debtor: ui.debtor,
          },
          target_sort: ui.sort,
          target_direction: ui.direction,
          target_limit: ui.pageSize,
          target_offset: ui.page * ui.pageSize,
        });
      } catch (error) {
        if (!schemaMissing(error)) throw error;
        try {
          result = await api().rpc("get_client_directory", {
            target_company_id: state.companyId,
            target_search: ui.search || null,
            target_status: ui.status || null,
            target_kind: ui.kind || null,
            target_assigned_user_id: ui.owner || null,
            target_limit: ui.pageSize,
            target_offset: ui.page * ui.pageSize,
          });
        } catch (fallbackError) {
          if (!schemaMissing(fallbackError)) throw fallbackError;
          result = fallbackDirectory(state);
        }
      }
      if (key !== directoryKey()) return;
      ui.directory = result || { items: [], total: 0 };
      ui.directoryKey = key;
    } catch (error) {
      ui.directoryError = error.message || "Chargement impossible.";
      ui.directory = { items: [], total: 0 };
    } finally {
      ui.directoryLoading = false;
      if (routeParts().path === "sales/clients") renderList(state);
    }
  }
  function scheduleDirectory(state) {
    clearTimeout(ui.timers.get("directory"));
    ui.timers.set(
      "directory",
      setTimeout(() => {
        ui.directory = null;
        loadDirectory(state);
      }, 220),
    );
  }
  function setListFilter(key, value) {
    ui[key] = value;
    ui.page = 0;
    ui.directory = null;
    scheduleDirectory(currentState);
    renderList(currentState);
  }
  function setBooleanFilter(key, value) {
    setListFilter(key, !!value);
  }
  function setSort(value) {
    const [field, direction] = String(value || "name:asc").split(":");
    ui.sort = field;
    ui.direction = direction === "desc" ? "desc" : "asc";
    ui.page = 0;
    ui.directory = null;
    loadDirectory(currentState);
    renderList(currentState);
  }
  function setSearch(value) {
    ui.search = value;
    setListFilter("search", value);
  }
  function setPage(page) {
    ui.page = Math.max(0, page);
    ui.directory = null;
    loadDirectory(currentState);
    renderList(currentState);
  }
  function toggleSelection(id, checked) {
    checked ? ui.selected.add(id) : ui.selected.delete(id);
    renderList(currentState);
  }
  function toggleAll(checked) {
    (ui.directory?.items || []).forEach((row) =>
      checked ? ui.selected.add(row.id) : ui.selected.delete(row.id),
    );
    renderList(currentState);
  }
  function toggleAdvanced() {
    ui.advanced = !ui.advanced;
    renderList(currentState);
  }
  function toggleColumn(key, checked) {
    ui.columns = checked
      ? [...new Set([...ui.columns, key])]
      : ui.columns.filter((x) => x !== key);
    if (!ui.columns.includes("select")) ui.columns.unshift("select");
    localStorage.setItem("piloz.client.columns", JSON.stringify(ui.columns));
    renderList(currentState);
  }
  function columnPicker() {
    return `<details class="client-column-picker"><summary class="btn btn-o">Colonnes</summary><div>${Object.entries(
      columnLabels,
    )
      .filter(([key]) => key !== "actions")
      .map(
        ([key, label]) =>
          `<label><input type="checkbox" ${ui.columns.includes(key) ? "checked" : ""} onchange="PilozClients.toggleColumn('${key}',this.checked)"><span>${esc(label)}</span></label>`,
      )
      .join("")}</div></details>`;
  }
  function cell(key, row, state) {
    const contact = [row.contact_first_name, row.contact_last_name]
      .filter(Boolean)
      .join(" ");
    if (key === "select")
      return `<td class="client-select" onclick="event.stopPropagation()"><input type="checkbox" aria-label="Sélectionner ${esc(clientName(row))}" ${ui.selected.has(row.id) ? "checked" : ""} onchange="PilozClients.toggleSelection('${row.id}',this.checked)"></td>`;
    if (key === "client")
      return `<td class="client-primary" data-label="Client"><span class="client-avatar">${esc(clientName(row).slice(0, 2).toUpperCase())}</span><span><b>${esc(clientName(row))}</b><small>${esc(row.trade_name && row.trade_name !== row.legal_name ? row.trade_name : row.siret || row.siren || "")}</small></span></td>`;
    if (key === "type")
      return `<td data-label="Type">${row.kind === "person" ? "Particulier" : "Professionnel"}</td>`;
    if (key === "contact")
      return `<td data-label="Contact principal">${esc(contact || "—")}<small>${esc(row.contact_email || "")}</small></td>`;
    if (key === "email")
      return `<td data-label="E-mail">${row.email ? `<a href="mailto:${esc(row.email)}" onclick="event.stopPropagation()">${esc(row.email)}</a>` : "—"}</td>`;
    if (key === "phone")
      return `<td data-label="Téléphone">${row.phone_e164 ? `<a href="tel:${esc(row.phone_e164)}" onclick="event.stopPropagation()">${esc(row.phone_e164)}</a>` : "—"}</td>`;
    if (key === "city")
      return `<td data-label="Ville">${esc(row.city || "—")}</td>`;
    if (key === "account")
      return `<td class="client-mono" data-label="Compte auxiliaire">${esc(row.auxiliary_account || "—")}</td>`;
    if (key === "owner")
      return `<td data-label="Responsable">${esc(memberName(state, row.assigned_user_id))}</td>`;
    if (key === "invoiced")
      return `<td class="client-money" data-label="Total facturé">${money(row.total_invoiced)}</td>`;
    if (key === "paid")
      return `<td class="client-money" data-label="Total encaissé">${money(row.total_paid)}</td>`;
    if (key === "outstanding")
      return `<td class="client-money ${Number(row.outstanding) > 0 ? "due" : ""}" data-label="Reste à payer">${money(row.outstanding)}${Number(row.overdue_count) > 0 ? `<small>${row.overdue_count} en retard</small>` : ""}</td>`;
    if (key === "last_document")
      return `<td data-label="Dernier document">${date(row.last_document_at)}</td>`;
    if (key === "status")
      return `<td data-label="Statut">${statusBadge(row.customer_status || "active")}</td>`;
    if (key === "actions")
      return `<td data-label="Actions" onclick="event.stopPropagation()"><div class="client-row-actions"><button title="Ouvrir" onclick="PilozClients.openClient('${row.id}')">↗</button><button title="Créer un devis" onclick="PilozApp.newClientDocument('${row.id}','quote')">＋</button></div></td>`;
    return "<td>—</td>";
  }
  function renderList(state) {
    if (!state) return;
    currentState = state;
    const main = document.getElementById("main");
    if (!main) return;
    const key = directoryKey();
    if ((!ui.directory || ui.directoryKey !== key) && !ui.directoryLoading)
      setTimeout(() => loadDirectory(state), 0);
    const result = ui.directory || { items: [], total: 0 },
      pages = Math.max(1, Math.ceil(Number(result.total || 0) / ui.pageSize)),
      activeRows = result.items || [];
    main.innerHTML = `<div class="client-workspace client-list-page"><header class="client-page-header"><div><span>Ventes</span><h1>Clients</h1><p>${Number(result.total || 0)} client${Number(result.total || 0) > 1 ? "s" : ""} · coordonnées, activité et suivi financier.</p></div><div class="client-header-actions">${button("Exporter CSV", "PilozClients.exportCsv()")}${button("Créer un client", "PilozClients.openClientCreator()", "btn-p")}</div></header><section class="client-toolbar"><label class="client-search"><span>⌕</span><input type="search" value="${esc(ui.search)}" placeholder="Nom, e-mail, téléphone, SIREN, SIRET, compte…" oninput="PilozClients.setSearch(this.value)"></label><select aria-label="Statut" onchange="PilozClients.setListFilter('status',this.value)"><option value="">Tous les statuts</option>${Object.entries(
      statusLabels,
    )
      .map(
        ([value, label]) =>
          `<option value="${value}" ${ui.status === value ? "selected" : ""}>${label}</option>`,
      )
      .join(
        "",
      )}</select><select aria-label="Type" onchange="PilozClients.setListFilter('kind',this.value)"><option value="">Tous les types</option><option value="company" ${ui.kind === "company" ? "selected" : ""}>Professionnels</option><option value="person" ${ui.kind === "person" ? "selected" : ""}>Particuliers</option></select>${button(ui.advanced ? "Masquer les filtres" : "Plus de filtres", "PilozClients.toggleAdvanced()")}${columnPicker()}</section>${ui.advanced ? `<section class="client-advanced-filters"><select onchange="PilozClients.setListFilter('owner',this.value)"><option value="">Tous les responsables</option>${(state.data.members || []).map((x) => `<option value="${x.user_id}" ${ui.owner === x.user_id ? "selected" : ""}>${esc(memberName(state, x.user_id))}</option>`).join("")}</select><span>Les soldes débiteurs et retards sont visibles directement dans les colonnes financières.</span></section>` : ""}${ui.selected.size ? `<div class="client-bulk-bar"><b>${ui.selected.size} sélectionné${ui.selected.size > 1 ? "s" : ""}</b>${button("Exporter la sélection", "PilozClients.exportCsv(true)")}${button("Effacer la sélection", "PilozClients.clearSelection()")}</div>` : ""}<section class="client-table-shell">${ui.directoryLoading ? skeleton(7) : ui.directoryError ? empty("Clients indisponibles", ui.directoryError, button("Réessayer", "PilozClients.retryDirectory()")) : activeRows.length ? `<div class="client-table-scroll"><table class="client-table"><thead><tr>${ui.columns.map((key) => (key === "select" ? `<th><input type="checkbox" aria-label="Tout sélectionner" onchange="PilozClients.toggleAll(this.checked)"></th>` : `<th>${esc(columnLabels[key] || key)}</th>`)).join("")}</tr></thead><tbody>${activeRows.map((row) => `<tr tabindex="0" onclick="PilozClients.openClient('${row.id}')" onkeydown="if(event.key==='Enter')PilozClients.openClient('${row.id}')">${ui.columns.map((key) => cell(key, row, state)).join("")}</tr>`).join("")}</tbody></table></div><footer class="client-pagination"><span>${ui.page * ui.pageSize + 1}–${Math.min((ui.page + 1) * ui.pageSize, result.total)} sur ${result.total}</span><div><button ${ui.page <= 0 ? "disabled" : ""} onclick="PilozClients.setPage(${ui.page - 1})">←</button><b>${ui.page + 1} / ${pages}</b><button ${ui.page >= pages - 1 ? "disabled" : ""} onclick="PilozClients.setPage(${ui.page + 1})">→</button></div></footer>` : empty("Aucun client", "Modifiez les filtres ou créez votre premier client.", button("Créer un client", "PilozClients.openClientCreator()", "btn-p"))}</section></div>`;
  }
  function retryDirectory() {
    ui.directory = null;
    loadDirectory(currentState);
  }
  function clearSelection() {
    ui.selected.clear();
    renderList(currentState);
  }
  function openClient(id, tab = "summary") {
    location.hash = `sales/clients/${id}?tab=${tab}`;
  }
  function exportCsv(selectedOnly = false) {
    const rows = (ui.directory?.items || []).filter(
        (row) => !selectedOnly || ui.selected.has(row.id),
      ),
      headers = [
        "Client",
        "Type",
        "Contact",
        "E-mail",
        "Téléphone",
        "Ville",
        "Compte auxiliaire",
        "Responsable",
        "Total facturé",
        "Total encaissé",
        "Reste à payer",
        "Dernier document",
        "Statut",
      ],
      lines = [
        headers,
        ...rows.map((row) => [
          clientName(row),
          row.kind === "person" ? "Particulier" : "Professionnel",
          [row.contact_first_name, row.contact_last_name]
            .filter(Boolean)
            .join(" "),
          row.email || "",
          row.phone_e164 || "",
          row.city || "",
          row.auxiliary_account || "",
          memberName(currentState, row.assigned_user_id),
          row.total_invoiced || 0,
          row.total_paid || 0,
          row.outstanding || 0,
          row.last_document_at || "",
          statusLabels[row.customer_status] || row.customer_status,
        ]),
      ],
      csv = lines
        .map((line) =>
          line
            .map((value) => `"${String(value ?? "").replaceAll('"', '""')}"`)
            .join(";"),
        )
        .join("\r\n"),
      url = URL.createObjectURL(
        new Blob(["\ufeff" + csv], { type: "text/csv;charset=utf-8" }),
      ),
      link = document.createElement("a");
    link.href = url;
    link.download = `clients-piloz-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  function detailEntry(id) {
    if (!ui.detail.has(id))
      ui.detail.set(id, {
        id,
        summary: null,
        loading: false,
        error: "",
        tabs: new Map(),
      });
    return ui.detail.get(id);
  }
  async function loadSummary(id, state) {
    const entry = detailEntry(id);
    if (entry.loading) return;
    entry.loading = true;
    entry.error = "";
    try {
      entry.summary = await api().rpc("get_client_workspace_summary", {
        target_client_id: id,
      });
      if (!entry.summary?.client) throw new Error("Client introuvable.");
    } catch (error) {
      entry.error = error.message || "Client introuvable.";
    } finally {
      entry.loading = false;
      const route = routeParts();
      if (route.path === `sales/clients/${id}`)
        renderDetail(id, state, route.query.get("tab") || "summary");
    }
  }
  async function loadTab(id, tab, state, force = false) {
    const entry = detailEntry(id);
    if (entry.tabs.has(tab) && !force) return entry.tabs.get(tab);
    entry.tabs.set(tab, { loading: true, rows: [], extra: {}, error: "" });
    renderDetail(id, state, tab);
    const cid = encodeURIComponent(id),
      company = encodeURIComponent(state.companyId);
    try {
      let rows = [],
        extra = {};
      if (tab === "summary") {
        const [
          contacts,
          addresses,
          documents,
          events,
          notes,
          files,
          activities,
        ] = await Promise.all([
          queryPath("client_contacts", [
            `select=*`,
            `client_id=eq.${cid}`,
            `active=eq.true`,
            `order=is_primary.desc,created_at`,
            `limit=5`,
          ]),
          queryPath("client_addresses", [
            `select=*`,
            `client_id=eq.${cid}`,
            `active=eq.true`,
            `order=is_primary.desc,created_at`,
            `limit=5`,
          ]),
          queryPath("documents", [
            `select=id,document_type,number,status,subject,issue_date,due_date,total_incl_tax,finalized_at,updated_at`,
            `client_id=eq.${cid}`,
            `order=updated_at.desc`,
            `limit=8`,
          ]),
          queryPath("client_activity_events", [
            `select=*`,
            `client_id=eq.${cid}`,
            `order=occurred_at.desc`,
            `limit=12`,
          ]),
          queryPath("client_notes", [
            `select=*`,
            `client_id=eq.${cid}`,
            `pinned=eq.true`,
            `order=updated_at.desc`,
            `limit=4`,
          ]),
          queryPath("client_documents", [
            `select=*`,
            `client_id=eq.${cid}`,
            `order=created_at.desc`,
            `limit=4`,
          ]),
          queryPath("activities", [
            `select=*`,
            `client_id=eq.${cid}`,
            `status=not.in.(completed,cancelled)`,
            `order=due_at.asc`,
            `limit=4`,
          ]),
        ]);
        const invoiceIds = documents
          .filter((document) => document.document_type !== "quote")
          .map((document) => document.id);
        const payments = invoiceIds.length
          ? await queryPath("payments", [
              `select=*`,
              `document_id=in.(${invoiceIds.join(",")})`,
              `order=paid_at.desc`,
              `limit=5`,
            ])
          : [];
        rows = events;
        extra = {
          contacts,
          addresses,
          documents,
          notes,
          files,
          activities,
          payments,
        };
      } else if (tab === "coordinates") {
        const [contacts, addresses] = await Promise.all([
          queryPath("client_contacts", [
            `select=*`,
            `client_id=eq.${cid}`,
            `active=eq.true`,
            `order=is_primary.desc,last_name`,
          ]),
          queryPath("client_addresses", [
            `select=*`,
            `client_id=eq.${cid}`,
            `active=eq.true`,
            `order=is_primary.desc,created_at`,
          ]),
        ]);
        extra = { contacts, addresses };
      } else if (tab === "contacts") {
        const [contacts, roles] = await Promise.all([
          queryPath("client_contacts", [
            `select=*`,
            `client_id=eq.${cid}`,
            `order=is_primary.desc,active.desc,last_name`,
          ]),
          queryPath("client_contact_roles", [
            `select=*`,
            `client_id=eq.${cid}`,
          ]),
        ]);
        rows = contacts;
        extra = { roles };
      } else if (tab === "addresses")
        rows = await queryPath("client_addresses", [
          `select=*`,
          `client_id=eq.${cid}`,
          `order=is_primary.desc,active.desc,created_at`,
        ]);
      else if (tab === "quotes")
        rows = await queryPath("documents", [
          `select=*`,
          `client_id=eq.${cid}`,
          `document_type=eq.quote`,
          `order=issue_date.desc`,
          `limit=100`,
        ]);
      else if (tab === "invoices")
        rows = await queryPath("documents", [
          `select=*`,
          `client_id=eq.${cid}`,
          `document_type=in.(invoice,deposit_invoice,balance_invoice,credit_note)`,
          `order=issue_date.desc`,
          `limit=100`,
        ]);
      else if (tab === "payments" || tab === "schedules") {
        const docs = await queryPath("documents", [
            `select=id,number,document_type,total_incl_tax,due_date,status`,
            `client_id=eq.${cid}`,
            `document_type=in.(invoice,deposit_invoice,balance_invoice,credit_note)`,
            `limit=500`,
          ]),
          ids = docs.map((x) => x.id);
        rows = ids.length
          ? await queryPath(
              tab === "payments" ? "payments" : "payment_schedules",
              [
                `select=*`,
                `document_id=in.(${ids.join(",")})`,
                `order=${tab === "payments" ? "paid_at" : "due_date"}.desc`,
                `limit=200`,
              ],
            )
          : [];
        extra = { documents: docs };
      } else if (tab === "activities")
        rows = await queryPath("activities", [
          `select=*`,
          `client_id=eq.${cid}`,
          `order=created_at.desc`,
          `limit=200`,
        ]);
      else if (tab === "accounting") {
        const profiles = await queryPath("client_accounting_profiles", [
          `select=client_id,auxiliary_account`,
          `client_id=eq.${cid}`,
          `limit=1`,
        ]);
        extra = { profile: profiles[0] || null };
      } else if (tab === "documents")
        rows = await queryPath("client_documents", [
          `select=*`,
          `client_id=eq.${cid}`,
          `order=created_at.desc`,
          `limit=200`,
        ]);
      else if (tab === "notes")
        rows = await queryPath("client_notes", [
          `select=*`,
          `client_id=eq.${cid}`,
          `order=pinned.desc,updated_at.desc`,
          `limit=200`,
        ]);
      else if (tab === "history")
        rows = await queryPath("client_activity_events", [
          `select=*`,
          `client_id=eq.${cid}`,
          `order=occurred_at.desc`,
          `limit=300`,
        ]);
      entry.tabs.set(tab, { loading: false, rows, extra, error: "" });
    } catch (error) {
      entry.tabs.set(tab, {
        loading: false,
        rows: [],
        extra: {},
        error: error.message || "Chargement impossible.",
      });
    }
    const route = routeParts();
    if (
      route.path === `sales/clients/${id}` &&
      (route.query.get("tab") || "summary") === tab
    )
      renderDetail(id, state, tab);
    return entry.tabs.get(tab);
  }
  function setTab(id, tab) {
    location.hash = `sales/clients/${id}?tab=${tab}`;
  }
  function metric(label, value, detail = "") {
    return `<article><span>${esc(label)}</span><b>${esc(value)}</b>${detail ? `<small>${esc(detail)}</small>` : ""}</article>`;
  }
  function detailHeader(entry, state, id, tab) {
    const data = entry.summary,
      c = data.client,
      contact = data.primary_contact,
      address = data.primary_address,
      metrics = data.metrics || {},
      outstanding = Math.max(
        0,
        Number(metrics.invoiced) - Number(metrics.paid),
      );
    return `<header class="client-detail-header"><div class="client-detail-nav"><button onclick="PilozApp.go('sales/clients')">← Clients</button><span>Fiche client</span></div><div class="client-detail-title"><span class="client-avatar large">${esc(clientName(c).slice(0, 2).toUpperCase())}</span><div><div class="client-title-line"><h1>${esc(clientName(c))}</h1>${statusBadge(c.customer_status || "active")}<span class="client-type">${c.kind === "person" ? "Particulier" : "Professionnel"}</span></div><p>${esc([contact && [contact.first_name, contact.last_name].filter(Boolean).join(" "), c.email, c.phone_e164, address?.city, c.siret && `SIRET ${c.siret}`, c.vat_number && `TVA ${c.vat_number}`].filter(Boolean).join(" · ") || "Coordonnées à compléter")}</p><small>Créé le ${date(c.created_at)} · Dernière activité ${date(data.last_activity_at)}</small><div class="client-header-meta"><span>Responsable : ${esc(memberName(state, c.assigned_user_id))}</span><span>Compte : ${esc(data.accounting?.auxiliary_account || "non attribué")}</span>${(c.tags || []).map((tag) => `<i>${esc(tag)}</i>`).join("")}</div></div><div class="client-detail-actions">${button("Créer un devis", `PilozApp.newClientDocument('${id}','quote')`, "btn-p")}${button("Créer une facture", `PilozApp.newClientDocument('${id}','invoice')`)}<details><summary class="btn btn-o">Actions</summary><div>${button("Modifier", `PilozClients.setTab('${id}','coordinates')`, "btn-ghost")}${button("Ajouter un contact", `PilozClients.openContactModal('${id}')`, "btn-ghost")}${button("Ajouter une adresse", `PilozClients.openAddressModal('${id}')`, "btn-ghost")}${button("Ajouter une activité", `PilozClients.openActivityModal('${id}')`, "btn-ghost")}${button("Ajouter une note", `PilozClients.openNoteModal('${id}')`, "btn-ghost")}${button("Ajouter un document", `PilozClients.setTab('${id}','documents')`, "btn-ghost")}${button("Rapport de doublons", `PilozClients.showDuplicates('${id}')`, "btn-ghost")}${button(c.customer_status === "inactive" ? "Réactiver" : "Désactiver", `PilozClients.changeClientStatus('${id}','${c.customer_status === "inactive" ? "active" : "inactive"}')`, "btn-ghost")}${button(c.customer_status === "archived" ? "Réactiver" : "Archiver", `PilozClients.changeClientStatus('${id}','${c.customer_status === "archived" ? "active" : "archived"}')`, "btn-ghost")}</div></details></div></div><section class="client-detail-kpis">${metric("Total devisé", money(metrics.quoted))}${metric("Total accepté", money(metrics.accepted))}${metric("Total facturé", money(metrics.invoiced))}${metric("Total encaissé", money(metrics.paid))}${metric("Reste à payer", money(outstanding))}${metric("Factures en retard", String(metrics.overdue || 0))}${metric("Activités en cours", String(metrics.open_activities || 0))}</section><nav class="client-tabs" aria-label="Rubriques du client">${tabs.map(([key, label]) => `<button class="${tab === key ? "active" : ""}" onclick="PilozClients.setTab('${id}','${key}')">${label}</button>`).join("")}</nav></header>`;
  }
  function renderDetail(id, state, tab = "summary") {
    currentState = state;
    const main = document.getElementById("main"),
      entry = detailEntry(id);
    if (!entry.summary && !entry.loading && !entry.error)
      setTimeout(() => loadSummary(id, state), 0);
    if (!entry.summary) {
      main.innerHTML = `<div class="client-workspace client-detail-page">${entry.error ? `<header class="client-page-header"><div><h1>Client introuvable</h1><p>${esc(entry.error)}</p></div></header>${empty("Accès impossible", "Ce client n’existe pas ou n’appartient pas à votre entreprise.", button("Retour aux clients", "PilozApp.go('sales/clients')"))}` : skeleton(8)}</div>`;
      return;
    }
    if (!entry.tabs.has(tab)) setTimeout(() => loadTab(id, tab, state), 0);
    const tabData = entry.tabs.get(tab) || {
      loading: true,
      rows: [],
      extra: {},
    };
    main.innerHTML = `<div class="client-workspace client-detail-page">${detailHeader(entry, state, id, tab)}<main class="client-tab-content">${tabData.loading ? skeleton(7) : tabData.error ? empty("Données indisponibles", tabData.error, button("Réessayer", `PilozClients.reloadTab('${id}','${tab}')`)) : renderTab(id, tab, entry, tabData, state)}</main></div>`;
  }
  function reloadTab(id, tab) {
    detailEntry(id).tabs.delete(tab);
    loadTab(id, tab, currentState, true);
  }
  function infoList(items) {
    return `<dl class="client-info-list">${items.map(([label, value]) => `<div><dt>${esc(label)}</dt><dd>${value || "—"}</dd></div>`).join("")}</dl>`;
  }
  function eventTimeline(rows) {
    return `<div class="client-timeline">${rows.map((row) => `<article><i></i><div><b>${esc(row.summary || row.event_type)}</b><p>${esc(row.metadata?.number || row.metadata?.subject || "")}</p><small>${datetime(row.occurred_at || row.created_at)}</small></div></article>`).join("")}</div>`;
  }
  function renderSummary(id, entry, data, state) {
    const s = entry.summary,
      c = s.client,
      contact = s.primary_contact,
      address = s.primary_address,
      pref = s.preferences || {},
      docs = data.extra.documents || [],
      quotes = docs.filter((x) => x.document_type === "quote"),
      invoices = docs.filter((x) => x.document_type !== "quote"),
      payments = data.extra.payments || [],
      files = data.extra.files || [],
      nextActivity = (data.extra.activities || [])[0];
    return `<div class="client-summary-grid"><section class="client-card"><header><h2>Informations principales</h2>${button("Modifier", `PilozClients.setTab('${id}','coordinates')`, "btn-ghost")}</header>${infoList(
      [
        ["Client", esc(clientName(c))],
        [
          "Contact principal",
          esc(
            contact
              ? [contact.first_name, contact.last_name]
                  .filter(Boolean)
                  .join(" ")
              : "—",
          ),
        ],
        [
          "Adresse principale",
          esc(
            address
              ? [address.address_line_1, address.postal_code, address.city]
                  .filter(Boolean)
                  .join(", ")
              : "—",
          ),
        ],
        ["Responsable", esc(memberName(state, c.assigned_user_id))],
        [
          "Compte auxiliaire",
          esc(s.accounting?.auxiliary_account || "Non attribué"),
        ],
        [
          "Conditions de paiement",
          esc(pref.payment_terms || c.payment_terms || "—"),
        ],
        [
          "Mode de paiement",
          esc(pref.payment_method || c.preferred_payment_method || "—"),
        ],
      ],
    )}</section><section class="client-card"><header><h2>Prochaine attention</h2>${button("Ajouter une activité", `PilozClients.openActivityModal('${id}')`, "btn-ghost")}</header>${Number(s.metrics?.overdue) ? `<div class="client-alert danger"><b>${s.metrics.overdue} facture(s) en retard</b><span>Consultez les échéances pour organiser la relance.</span></div>` : '<div class="client-alert success"><b>Aucun retard détecté</b><span>La situation client est à jour.</span></div>'}<p class="client-muted">${nextActivity ? `${esc(nextActivity.subject)} · ${datetime(nextActivity.due_at || nextActivity.scheduled_at)}` : `${Number(s.metrics?.open_activities) || 0} activité(s) encore ouverte(s).`}</p></section><section class="client-card wide"><header><h2>Derniers devis</h2>${button("Voir tous", `PilozClients.setTab('${id}','quotes')`, "btn-ghost")}</header>${miniDocuments(quotes)}</section><section class="client-card wide"><header><h2>Dernières factures</h2>${button("Voir toutes", `PilozClients.setTab('${id}','invoices')`, "btn-ghost")}</header>${miniDocuments(invoices)}</section><section class="client-card"><header><h2>Derniers paiements</h2>${button("Voir tous", `PilozClients.setTab('${id}','payments')`, "btn-ghost")}</header>${payments.map((payment) => `<article class="client-note-mini"><b>${money(payment.amount, payment.currency)}</b><p>${esc(payment.payment_method || "Paiement")} · ${esc(payment.reference || "sans référence")}</p><small>${datetime(payment.paid_at)}</small></article>`).join("") || '<p class="client-muted">Aucun paiement.</p>'}</section><section class="client-card"><header><h2>Documents récents</h2>${button("Voir tous", `PilozClients.setTab('${id}','documents')`, "btn-ghost")}</header>${files.map((file) => `<article class="client-note-mini"><b>${esc(file.file_name)}</b><p>${esc(file.document_type || "Document")}</p><small>${date(file.document_date || file.created_at)}</small></article>`).join("") || '<p class="client-muted">Aucun document joint.</p>'}</section><section class="client-card"><header><h2>Notes épinglées</h2>${button("Ajouter", `PilozClients.openNoteModal('${id}')`, "btn-ghost")}</header>${(data.extra.notes || []).map((x) => `<article class="client-note-mini"><b>Note</b><p>${esc(x.body)}</p><small>${date(x.updated_at)}</small></article>`).join("") || '<p class="client-muted">Aucune note épinglée.</p>'}</section><section class="client-card timeline-card"><header><h2>Chronologie récente</h2>${button("Historique complet", `PilozClients.setTab('${id}','history')`, "btn-ghost")}</header>${data.rows.length ? eventTimeline(data.rows) : '<p class="client-muted">Aucun événement récent.</p>'}</section></div>`;
  }
  function miniDocuments(rows) {
    return rows.length
      ? `<div class="client-mini-docs">${rows
          .slice(0, 5)
          .map(
            (x) =>
              `<button onclick="PilozApp.editDocument('${x.id}')"><span><b>${esc(x.number || "Brouillon")}</b><small>${esc(x.subject || date(x.issue_date))}</small></span><strong>${money(x.total_incl_tax)}</strong></button>`,
          )
          .join("")}</div>`
      : '<p class="client-muted">Aucun document.</p>';
  }
  function coordinatesForm(id, c, state, data = { extra: {} }) {
    const professional = c.kind !== "person";
    return `<form id="client-coordinates-form" class="client-form" onsubmit="event.preventDefault();PilozClients.saveCoordinates('${id}')"><header><div><h2>Coordonnées</h2><p>Les coordonnées courantes du client. Les anciens documents finalisés restent figés.</p></div>${button("Enregistrer", "", "btn-p", 'type="submit" data-client-save')}</header><div class="client-form-grid"><label><span>Type</span><select name="kind" onchange="PilozClients.toggleCoordinateKind(this.value)"><option value="company" ${professional ? "selected" : ""}>Professionnel</option><option value="person" ${!professional ? "selected" : ""}>Particulier</option></select></label><label><span>Statut</span><select name="customer_status">${Object.entries(
      statusLabels,
    )
      .map(
        ([value, label]) =>
          `<option value="${value}" ${(c.customer_status || "active") === value ? "selected" : ""}>${label}</option>`,
      )
      .join(
        "",
      )}</select></label><div data-professional ${professional ? "" : "hidden"}><label><span>Raison sociale *</span><input name="legal_name" value="${esc(c.legal_name || "")}"></label><label><span>Nom commercial</span><input name="trade_name" value="${esc(c.trade_name || "")}"></label><label><span>Forme juridique</span><input name="legal_form" value="${esc(c.legal_form || "")}"></label><label><span>SIREN</span><input name="siren" value="${esc(c.siren || "")}"></label><label><span>SIRET</span><input name="siret" value="${esc(c.siret || "")}"></label><label><span>Code APE</span><input name="ape_code" value="${esc(c.ape_code || "")}"></label><label><span>Numéro de TVA</span><input name="vat_number" value="${esc(c.vat_number || "")}"></label></div><div data-person ${professional ? "hidden" : ""}><label><span>Civilité</span><select name="civility"><option value="">—</option><option value="M." ${c.civility === "M." ? "selected" : ""}>M.</option><option value="Mme" ${c.civility === "Mme" ? "selected" : ""}>Mme</option></select></label><label><span>Prénom *</span><input name="first_name" value="${esc(c.first_name || "")}"></label><label><span>Nom *</span><input name="last_name" value="${esc(c.last_name || "")}"></label></div><label><span>E-mail général</span><input name="email" type="email" value="${esc(c.email || "")}"></label><label><span>Téléphone</span><input name="phone_e164" type="tel" value="${esc(c.phone_e164 || "")}"></label><label><span>Second téléphone</span><input name="secondary_phone_e164" type="tel" value="${esc(c.secondary_phone_e164 || "")}"></label><label><span>Site internet</span><input name="website" type="url" value="${esc(c.website || "")}"></label><label><span>Langue</span><select name="language"><option value="fr">Français</option><option value="en" ${c.language === "en" ? "selected" : ""}>English</option></select></label><label><span>Responsable commercial</span><select name="assigned_user_id"><option value="">Non attribué</option>${(state.data.members || []).map((x) => `<option value="${x.user_id}" ${c.assigned_user_id === x.user_id ? "selected" : ""}>${esc(memberName(state, x.user_id))}</option>`).join("")}</select></label><label class="full"><span>Tags (séparés par des virgules)</span><input name="tags" value="${esc((c.tags || []).join(", "))}"></label><label class="full"><span>Notes internes</span><textarea name="internal_notes" rows="5">${esc(c.internal_notes || "")}</textarea></label></div></form>${preferencesForm(id, entryFor(id)?.summary?.preferences || {}, c, state)}`;
  }
  function entryFor(id) {
    return ui.detail.get(id);
  }
  function toggleCoordinateKind(kind) {
    document
      .querySelector("[data-professional]")
      ?.toggleAttribute("hidden", kind !== "company");
    document
      .querySelector("[data-person]")
      ?.toggleAttribute("hidden", kind !== "person");
  }
  function preferencesForm(id, pref, c, state, data = { extra: {} }) {
    const coordinateData = entryFor(id)?.tabs.get("coordinates") ||
        data || { extra: {} },
      contacts = coordinateData.extra?.contacts || [],
      addresses = coordinateData.extra?.addresses || [],
      members = state.data.members || [],
      footers = state.data.documentFooters || [],
      option = (value, selected, label) =>
        `<option value="${value}" ${selected === value ? "selected" : ""}>${esc(label)}</option>`,
      contactOptions = contacts
        .map((x) =>
          option(
            x.id,
            pref.default_contact_id,
            [x.first_name, x.last_name, x.job_title]
              .filter(Boolean)
              .join(" · "),
          ),
        )
        .join(""),
      addressOptions = (selected) =>
        addresses
          .map((x) =>
            option(
              x.id,
              selected,
              [x.label, x.city].filter(Boolean).join(" · "),
            ),
          )
          .join("");
    return `<form id="client-preferences-form" class="client-form client-preferences" onsubmit="event.preventDefault();PilozClients.savePreferences('${id}')">
      <header><div><h2>Préférences commerciales</h2><p>Reprises automatiquement dans les nouveaux devis et factures.</p></div>${button("Enregistrer les préférences", "", "btn-o", 'type="submit" data-client-save')}</header>
      <div class="client-form-grid">
        <label><span>Conditions de paiement</span><input name="payment_terms" value="${esc(pref.payment_terms || c.payment_terms || "")}"></label>
        <label><span>Délai (jours)</span><input name="payment_delay_days" type="number" min="0" value="${esc(pref.payment_delay_days ?? "")}"></label>
        <label><span>Mode de paiement préféré</span><input name="payment_method" value="${esc(pref.payment_method || c.preferred_payment_method || "")}"></label>
        <label><span>Devise</span><input name="currency" maxlength="3" value="${esc(pref.currency || "EUR")}"></label>
        <label><span>Remise habituelle (%)</span><input name="usual_discount_rate" type="number" min="0" max="100" step="0.01" value="${Number(pref.usual_discount_rate ?? c.discount_rate) || 0}"></label>
        <label><span>Langue</span><select name="language"><option value="fr">Français</option><option value="en" ${pref.language === "en" ? "selected" : ""}>English</option></select></label>
        <label><span>Responsable commercial</span><select name="assigned_user_id"><option value="">Non attribué</option>${members.map((x) => option(x.user_id, pref.assigned_user_id || c.assigned_user_id, memberName(state, x.user_id))).join("")}</select></label>
        <label><span>Contact principal par défaut</span><select name="default_contact_id"><option value="">Automatique</option>${contactOptions}</select></label>
        <label><span>Contact de facturation</span><select name="billing_contact_id"><option value="">Contact principal</option>${contacts.map((x) => option(x.id, pref.billing_contact_id, [x.first_name, x.last_name, x.job_title].filter(Boolean).join(" · "))).join("")}</select></label>
        <label><span>Adresse de facturation</span><select name="billing_address_id"><option value="">Adresse par défaut</option>${addressOptions(pref.billing_address_id)}</select></label>
        <label><span>Adresse de livraison</span><select name="shipping_address_id"><option value="">Adresse par défaut</option>${addressOptions(pref.shipping_address_id)}</select></label>
        <label><span>Adresse d’intervention</span><select name="service_address_id"><option value="">Adresse par défaut</option>${addressOptions(pref.service_address_id)}</select></label>
        <label><span>Modèle de devis</span><select name="quote_template_id"><option value="">Modèle entreprise</option>${(
          state.data.templates || []
        )
          .filter((x) => x.document_type === "quote" && x.status === "active")
          .map((x) => option(x.id, pref.quote_template_id, x.name))
          .join("")}</select></label>
        <label><span>Modèle de facture</span><select name="invoice_template_id"><option value="">Modèle entreprise</option>${(
          state.data.templates || []
        )
          .filter((x) => x.document_type === "invoice" && x.status === "active")
          .map((x) => option(x.id, pref.invoice_template_id, x.name))
          .join("")}</select></label>
        <label><span>Pied de page préféré</span><select name="footer_id"><option value="">Pied de page du modèle</option>${footers.map((x) => option(x.id, pref.footer_id, x.name || "Pied de page")).join("")}</select></label>
        <label class="full"><span>Notes visibles dans les nouveaux documents</span><textarea name="document_notes">${esc(pref.document_notes || "")}</textarea></label>
        <label class="full"><span>Notes internes des préférences</span><textarea name="internal_notes">${esc(pref.internal_notes || "")}</textarea></label>
      </div>
    </form>`;
  }
  function contactCard(id, row, roles) {
    const assigned = roles
      .filter((x) => x.contact_id === row.id)
      .map((x) => roleLabels[x.role] || x.role);
    return `<article class="client-contact-card ${row.active ? "" : "inactive"}"><header><span class="client-avatar">${esc(([row.first_name, row.last_name].filter(Boolean).join(" ") || "C").slice(0, 2).toUpperCase())}</span><div><h3>${esc([row.civility, row.first_name, row.last_name].filter(Boolean).join(" "))}</h3><p>${esc([row.job_title, row.department].filter(Boolean).join(" · ") || "Fonction non renseignée")}</p></div>${row.is_primary ? '<span class="modern-status success">Principal</span>' : ""}</header><div class="client-chips">${assigned.map((x) => `<span>${esc(x)}</span>`).join("")}</div>${infoList(
      [
        [
          "E-mail",
          row.email
            ? `<a href="mailto:${esc(row.email)}">${esc(row.email)}</a>`
            : "—",
        ],
        [
          "Téléphone",
          row.phone_e164
            ? `<a href="tel:${esc(row.phone_e164)}">${esc(row.phone_e164)}</a>`
            : "—",
        ],
        ["Mobile", esc(row.mobile_e164 || "—")],
        ["Contact préféré", esc(row.preferred_contact_method || "—")],
      ],
    )}<footer>${button("Modifier", `PilozClients.openContactModal('${id}','${row.id}')`, "btn-ghost")}${button(row.active ? "Désactiver" : "Réactiver", `PilozClients.toggleContact('${id}','${row.id}',${!row.active})`, "btn-ghost")}${row.email ? button("E-mail", `location.href='mailto:${encodeURIComponent(row.email)}'`, "btn-ghost") : ""}${row.phone_e164 ? button("Appeler", `location.href='tel:${encodeURIComponent(row.phone_e164)}'`, "btn-ghost") : ""}${button("Créer une activité", `PilozClients.openActivityModal('${id}','${row.id}')`, "btn-ghost")}</footer></article>`;
  }
  function renderContacts(id, data) {
    const roles = data.extra.roles || [];
    return `<section class="client-section-heading"><div><h2>Contacts</h2><p>Plusieurs contacts actifs peuvent être associés au même client.</p></div>${button("Ajouter un contact", `PilozClients.openContactModal('${id}')`, "btn-p")}</section>${data.rows.length ? `<div class="client-card-grid">${data.rows.map((row) => contactCard(id, row, roles)).join("")}</div>` : empty("Aucun contact", "Ajoutez le contact principal, le signataire ou le contact facturation.", button("Ajouter un contact", `PilozClients.openContactModal('${id}')`, "btn-p"))}`;
  }
  function addressCard(id, row) {
    const flags = [
      row.is_primary && "Principale",
      row.is_default_billing && "Facturation par défaut",
      row.is_default_shipping && "Livraison par défaut",
      row.is_default_service && "Intervention par défaut",
    ].filter(Boolean);
    return `<article class="client-address-card ${row.active ? "" : "inactive"}"><header><div><small>${esc(addressLabels[row.address_type] || row.address_type)}</small><h3>${esc(row.label)}</h3></div>${row.is_primary ? '<span class="modern-status success">Principale</span>' : ""}</header><address><b>${esc(row.recipient_name || row.company_name || "")}</b><span>${esc(row.address_line_1)}</span><span>${esc([row.address_line_2, row.complement].filter(Boolean).join(" · "))}</span><span>${esc([row.postal_code, row.city, row.region].filter(Boolean).join(" "))}</span><span>${esc(row.country_code || "FR")}</span></address><div class="client-chips">${flags.map((x) => `<span>${esc(x)}</span>`).join("")}</div>${row.instructions ? `<p class="client-address-instructions">${esc(row.instructions)}</p>` : ""}<footer>${button("Modifier", `PilozClients.openAddressModal('${id}','${row.id}')`, "btn-ghost")}${button(row.active ? "Désactiver" : "Réactiver", `PilozClients.toggleAddress('${id}','${row.id}',${!row.active})`, "btn-ghost")}</footer></article>`;
  }
  function renderAddresses(id, data) {
    return `<section class="client-section-heading"><div><h2>Adresses</h2><p>Facturation, livraison, intervention et établissements du client.</p></div>${button("Ajouter une adresse", `PilozClients.openAddressModal('${id}')`, "btn-p")}</section>${data.rows.length ? `<div class="client-card-grid">${data.rows.map((row) => addressCard(id, row)).join("")}</div>` : empty("Aucune adresse", "Ajoutez une adresse principale ou une adresse de facturation.", button("Ajouter une adresse", `PilozClients.openAddressModal('${id}')`, "btn-p"))}`;
  }
  function documentStatus(row) {
    if (row.document_type === "quote")
      return (
        {
          draft: "Brouillon",
          pending: "En attente",
          sent: "En attente",
          accepted: "Accepté",
          rejected: "Refusé",
          invoiced: "Facturé",
          expired: "Expiré",
        }[row.status] || row.status
      );
    return row.finalized_at
      ? {
          paid: "Encaissée",
          partially_paid: "Partiellement encaissée",
          overdue: "En retard",
          cancelled: "Annulée",
        }[row.status] || "Finalisée"
      : "Brouillon";
  }
  function renderDocumentsTab(id, data, kind) {
    const isQuote = kind === "quote",
      rows = data.rows;
    return `<section class="client-section-heading"><div><h2>${isQuote ? "Devis" : "Factures"}</h2><p>${rows.length} document${rows.length > 1 ? "s" : ""} lié${rows.length > 1 ? "s" : ""} à ce client.</p></div>${button(isQuote ? "Créer un devis" : "Créer une facture", `PilozApp.newClientDocument('${id}','${isQuote ? "quote" : "invoice"}')`, "btn-p")}</section>${rows.length ? `<div class="client-doc-table"><table><thead><tr><th>Numéro</th><th>Objet</th><th>Émission</th><th>${isQuote ? "Validité" : "Échéance"}</th><th>Contact</th><th>Montant HT</th><th>TTC</th><th>Statut</th><th></th></tr></thead><tbody>${rows.map((row) => `<tr onclick="PilozApp.editDocument('${row.id}')"><td><b>${esc(row.number || "Brouillon")}</b></td><td>${esc(row.subject || "—")}</td><td>${date(row.issue_date)}</td><td>${date(isQuote ? row.validity_date : row.due_date)}</td><td>${esc((currentState.data.clientContacts || []).find((x) => x.id === row.contact_id)?.last_name || "—")}</td><td>${money(row.total_excl_tax, row.currency)}</td><td><b>${money(row.total_incl_tax, row.currency)}</b></td><td><span class="modern-status neutral">${esc(documentStatus(row))}</span></td><td><button onclick="event.stopPropagation();PilozApp.editDocument('${row.id}')">Ouvrir</button></td></tr>`).join("")}</tbody></table></div>` : empty(`Aucun ${isQuote ? "devis" : "facture"}`, `Créez ${isQuote ? "un devis" : "une facture"} depuis cette fiche : le client, son contact et ses adresses seront présélectionnés.`, button(isQuote ? "Créer un devis" : "Créer une facture", `PilozApp.newClientDocument('${id}','${isQuote ? "quote" : "invoice"}')`, "btn-p"))}`;
  }
  function renderPayments(data) {
    const docs = new Map((data.extra.documents || []).map((x) => [x.id, x]));
    return `<section class="client-section-heading"><div><h2>Paiements</h2><p>Registre append-only des encaissements et corrections.</p></div></section>${data.rows.length ? `<div class="client-doc-table"><table><thead><tr><th>Date</th><th>Facture</th><th>Montant</th><th>Mode</th><th>Référence</th><th>Statut</th><th>Enregistré par</th></tr></thead><tbody>${data.rows.map((row) => `<tr onclick="PilozApp.editDocument('${row.document_id}')"><td>${datetime(row.paid_at)}</td><td><b>${esc(docs.get(row.document_id)?.number || "—")}</b></td><td>${money(row.amount, row.currency)}</td><td>${esc(row.payment_method || "—")}</td><td>${esc(row.reference || "—")}</td><td>${esc(row.entry_type === "payment" ? "Paiement" : row.entry_type || row.status)}</td><td>${esc(memberName(currentState, row.created_by))}</td></tr>`).join("")}</tbody></table></div>` : empty("Aucun paiement", "Les paiements enregistrés depuis les factures apparaîtront ici.")}`;
  }
  function renderSchedules(data) {
    const docs = new Map((data.extra.documents || []).map((x) => [x.id, x])),
      today = new Date().toISOString().slice(0, 10);
    return `<section class="client-section-heading"><div><h2>Échéances</h2><p>Montants à venir, partiels et en retard.</p></div></section>${
      data.rows.length
        ? `<div class="client-doc-table"><table><thead><tr><th>Facture</th><th>Échéance</th><th>Montant</th><th>Encaissé</th><th>Reste</th><th>Retard</th><th>Statut</th></tr></thead><tbody>${data.rows
            .map((row) => {
              const remaining = Math.max(
                  0,
                  Number(row.amount) - Number(row.paid_amount),
                ),
                days = Math.ceil(
                  (new Date(today) - new Date(row.due_date)) / 86400000,
                );
              return `<tr onclick="PilozApp.editDocument('${row.document_id}')"><td><b>${esc(docs.get(row.document_id)?.number || "—")}</b></td><td>${date(row.due_date)}</td><td>${money(row.amount)}</td><td>${money(row.paid_amount)}</td><td><b>${money(remaining)}</b></td><td>${days > 0 ? `${days} jour(s)` : "—"}</td><td>${esc(remaining <= 0 ? "Encaissée" : days > 0 ? "En retard" : row.status)}</td></tr>`;
            })
            .join("")}</tbody></table></div>`
        : empty(
            "Aucune échéance",
            "Les échéances des factures finalisées apparaîtront ici.",
          )
    }`;
  }
  function renderActivities(id, data) {
    return `<section class="client-section-heading"><div><h2>Activités</h2><p>Appels, e-mails, rendez-vous, tâches, relances et suivis.</p></div>${button("Ajouter une activité", `PilozClients.openActivityModal('${id}')`, "btn-p")}</section>${data.rows.length ? `<div class="client-activity-list">${data.rows.map((row) => `<article><span class="client-activity-icon">${esc((row.activity_type || "note").slice(0, 1).toUpperCase())}</span><div><b>${esc(row.subject)}</b><p>${esc(row.description || row.comment || "")}</p><small>${datetime(row.due_at || row.scheduled_at || row.created_at)} · ${esc(memberName(currentState, row.assigned_user_id))}</small></div><span class="modern-status ${row.status === "completed" ? "success" : "neutral"}">${esc(row.status || "À faire")}</span></article>`).join("")}</div>` : empty("Aucune activité", "Ajoutez un appel, une tâche ou un rendez-vous.", button("Ajouter une activité", `PilozClients.openActivityModal('${id}')`, "btn-p"))}`;
  }
  function renderAccounting(id, entry, data) {
    const profile = data.extra.profile || entry.summary.accounting || {};
    return `<form id="client-account-form" class="client-form client-auxiliary-account-form" onsubmit="event.preventDefault();PilozClients.saveAccounting('${id}')"><header><div><h2>Code auxiliaire</h2><p>Ce code identifiera le client dans la future comptabilité. Le paramétrage général sera ajouté plus tard dans les Paramètres.</p></div>${button("Enregistrer", "", "btn-p", 'type="submit" data-client-save')}</header><label><span>Code auxiliaire</span><input name="auxiliary_account" value="${esc(profile.auxiliary_account || "")}" maxlength="64" placeholder="Ex. CLI000042" autocomplete="off" required></label></form>`;
  }
  function renderClientFiles(id, data) {
    return `<section class="client-section-heading"><div><h2>Documents</h2><p>Contrats, bons de commande, attestations et fichiers administratifs.</p></div><label class="btn btn-p client-upload">Ajouter un document<input type="file" hidden onchange="PilozClients.uploadClientFile('${id}',this.files[0])"></label></section>${data.rows.length ? `<div class="client-files">${data.rows.map((row) => `<article><span>▤</span><div><b>${esc(row.file_name)}</b><small>${esc(row.document_type)} · ${row.size_bytes ? Math.ceil(row.size_bytes / 1024) + " Ko" : "Taille inconnue"} · ${date(row.document_date || row.created_at)}</small></div>${button("Télécharger", `PilozClients.downloadClientFile('${row.id}')`, "btn-ghost")}</article>`).join("")}</div>` : empty("Aucun document", "Ajoutez un contrat, un bon de commande ou une attestation.")}`;
  }
  function renderNotes(id, data) {
    return `<section class="client-section-heading"><div><h2>Notes</h2><p>Notes internes uniquement. Elles ne sont jamais imprimées sur les PDF automatiquement.</p></div>${button("Ajouter une note", `PilozClients.openNoteModal('${id}')`, "btn-p")}</section>${data.rows.length ? `<div class="client-notes-grid">${data.rows.map((row) => `<article class="client-note ${row.pinned ? "pinned" : ""}"><header><span>${row.pinned ? "Épinglée" : "Note interne"}</span><small>${datetime(row.updated_at)}</small></header><p>${esc(row.body)}</p><footer>${button("Modifier", `PilozClients.openNoteModal('${id}','${row.id}')`, "btn-ghost")}${button(row.pinned ? "Désépingler" : "Épingler", `PilozClients.toggleNotePin('${id}','${row.id}',${!row.pinned})`, "btn-ghost")}${button("Supprimer", `PilozClients.deleteNote('${id}','${row.id}')`, "btn-ghost")}</footer></article>`).join("")}</div>` : empty("Aucune note", "Ajoutez une information utile pour votre équipe.", button("Ajouter une note", `PilozClients.openNoteModal('${id}')`, "btn-p"))}`;
  }
  function renderTab(id, tab, entry, data, state) {
    if (tab === "summary") return renderSummary(id, entry, data, state);
    if (tab === "coordinates")
      return coordinatesForm(id, entry.summary.client, state, data);
    if (tab === "contacts") return renderContacts(id, data);
    if (tab === "addresses") return renderAddresses(id, data);
    if (tab === "quotes") return renderDocumentsTab(id, data, "quote");
    if (tab === "invoices") return renderDocumentsTab(id, data, "invoice");
    if (tab === "payments") return renderPayments(data);
    if (tab === "schedules") return renderSchedules(data);
    if (tab === "activities") return renderActivities(id, data);
    if (tab === "accounting") return renderAccounting(id, entry, data);
    if (tab === "documents") return renderClientFiles(id, data);
    if (tab === "notes") return renderNotes(id, data);
    if (tab === "history")
      return `<section class="client-section-heading"><div><h2>Historique complet</h2><p>Chronologie unifiée des modifications, documents, paiements et activités.</p></div></section>${data.rows.length ? eventTimeline(data.rows) : empty("Aucun événement", "Les prochaines actions seront consignées ici.")}`;
    return empty("Rubrique indisponible", "Cette rubrique n’existe pas.");
  }

  function invalidate(id, tab) {
    const entry = detailEntry(id);
    if (tab) entry.tabs.delete(tab);
    else {
      entry.summary = null;
      entry.tabs.clear();
    }
    return entry;
  }
  async function saveCoordinates(id) {
    const raw = formData("client-coordinates-form"),
      professional = raw.kind === "company",
      payload = {
        kind: raw.kind,
        customer_status: raw.customer_status,
        legal_name: professional ? raw.legal_name?.trim() || null : null,
        trade_name: professional ? raw.trade_name || null : null,
        legal_form: professional ? raw.legal_form || null : null,
        siren: professional ? raw.siren || null : null,
        siret: professional ? raw.siret || null : null,
        ape_code: professional ? raw.ape_code || null : null,
        vat_number: professional ? raw.vat_number || null : null,
        civility: professional ? null : raw.civility || null,
        first_name: professional ? null : raw.first_name?.trim() || null,
        last_name: professional ? null : raw.last_name?.trim() || null,
        email: raw.email?.trim().toLowerCase() || null,
        phone_e164: raw.phone_e164 || null,
        secondary_phone_e164: raw.secondary_phone_e164 || null,
        website: raw.website || null,
        language: raw.language || "fr",
        assigned_user_id: raw.assigned_user_id || null,
        tags: String(raw.tags || "")
          .split(",")
          .map((x) => x.trim())
          .filter(Boolean),
        internal_notes: raw.internal_notes || null,
        active: !["inactive", "archived"].includes(raw.customer_status),
      };
    if (professional && !payload.legal_name) {
      notify("La raison sociale est obligatoire.", "error");
      return;
    }
    if (!professional && (!payload.first_name || !payload.last_name)) {
      notify("Le prénom et le nom sont obligatoires.", "error");
      return;
    }
    setBusy(true);
    try {
      await api().update("clients", id, payload);
      invalidate(id);
      await app().refresh();
      openClient(id, "coordinates");
      notify("Coordonnées enregistrées.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function savePreferences(id) {
    const raw = formData("client-preferences-form"),
      payload = {
        payment_terms: raw.payment_terms || null,
        payment_delay_days: raw.payment_delay_days || null,
        payment_method: raw.payment_method || null,
        currency: (raw.currency || "EUR").toUpperCase(),
        usual_discount_rate: Number(raw.usual_discount_rate) || 0,
        language: raw.language || "fr",
        quote_template_id: raw.quote_template_id || null,
        invoice_template_id: raw.invoice_template_id || null,
        assigned_user_id: raw.assigned_user_id || null,
        default_contact_id: raw.default_contact_id || null,
        billing_contact_id: raw.billing_contact_id || null,
        billing_address_id: raw.billing_address_id || null,
        shipping_address_id: raw.shipping_address_id || null,
        service_address_id: raw.service_address_id || null,
        footer_id: raw.footer_id || null,
        document_notes: raw.document_notes || null,
        internal_notes: raw.internal_notes || null,
      };
    setBusy(true);
    try {
      await api().rpc("save_client_preferences", {
        target_client_id: id,
        target_preferences: payload,
      });
      invalidate(id);
      await loadSummary(id, currentState);
      notify("Préférences enregistrées.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  function openContactModal(clientId, contactId = null, documentMode = false) {
    const entry = detailEntry(clientId),
      contacts =
        entry.tabs.get("contacts")?.rows ||
        currentState?.data?.clientContacts ||
        [],
      roles = entry.tabs.get("contacts")?.extra?.roles || [],
      row = contacts.find((x) => x.id === contactId) || {},
      assigned = roles
        .filter((x) => x.contact_id === contactId)
        .map((x) => x.role);
    openDrawer(
      contactId ? "Modifier le contact" : "Nouveau contact",
      `<form id="client-contact-form" class="client-form drawer-form" onsubmit="event.preventDefault();PilozClients.saveContact('${clientId}','${contactId || ""}',${documentMode})"><div class="client-form-grid"><label><span>Civilité</span><select name="civility"><option value="">—</option><option value="M." ${row.civility === "M." ? "selected" : ""}>M.</option><option value="Mme" ${row.civility === "Mme" ? "selected" : ""}>Mme</option></select></label><label><span>Prénom *</span><input name="first_name" required value="${esc(row.first_name || "")}"></label><label><span>Nom *</span><input name="last_name" required value="${esc(row.last_name || "")}"></label><label><span>Fonction</span><input name="job_title" value="${esc(row.job_title || "")}"></label><label><span>Service</span><input name="department" value="${esc(row.department || "")}"></label><label><span>E-mail professionnel</span><input name="email" type="email" value="${esc(row.email || "")}"></label><label><span>E-mail secondaire</span><input name="secondary_email" type="email" value="${esc(row.secondary_email || "")}"></label><label><span>Téléphone</span><input name="phone_e164" type="tel" value="${esc(row.phone_e164 || "")}"></label><label><span>Mobile</span><input name="mobile_e164" type="tel" value="${esc(row.mobile_e164 || "")}"></label><label><span>Langue</span><select name="language"><option value="fr">Français</option><option value="en" ${row.language === "en" ? "selected" : ""}>English</option></select></label><label><span>Contact préféré</span><select name="preferred_contact_method"><option value="">Non précisé</option><option value="email" ${row.preferred_contact_method === "email" ? "selected" : ""}>E-mail</option><option value="phone" ${row.preferred_contact_method === "phone" ? "selected" : ""}>Téléphone</option><option value="mobile" ${row.preferred_contact_method === "mobile" ? "selected" : ""}>Mobile</option></select></label><label class="full"><span>Commentaire interne</span><textarea name="internal_comment">${esc(row.internal_comment || "")}</textarea></label><fieldset class="full"><legend>Rôles</legend><div class="client-role-grid">${Object.entries(
        roleLabels,
      )
        .map(
          ([value, label]) =>
            `<label class="check"><input name="roles" type="checkbox" value="${value}" ${assigned.includes(value) || (value === "primary" && row.is_primary) ? "checked" : ""}><span>${label}</span></label>`,
        )
        .join(
          "",
        )}</div></fieldset><label class="check"><input name="active" type="checkbox" ${row.active !== false ? "checked" : ""}><span>Contact actif</span></label></div><footer>${button("Annuler", "PilozClients.closeDrawer()")}${button("Enregistrer", "", "btn-p", 'type="submit" data-client-save')}</footer></form>`,
      true,
    );
  }
  async function saveContact(clientId, contactId = "", documentMode = false) {
    const form = document.getElementById("client-contact-form");
    if (!form?.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form)),
      roles = [...form.querySelectorAll('[name="roles"]:checked')].map(
        (x) => x.value,
      ),
      payload = {
        id: contactId || null,
        civility: raw.civility || null,
        first_name: raw.first_name.trim(),
        last_name: raw.last_name.trim(),
        job_title: raw.job_title || null,
        department: raw.department || null,
        email: raw.email || null,
        secondary_email: raw.secondary_email || null,
        phone_e164: raw.phone_e164 || null,
        mobile_e164: raw.mobile_e164 || null,
        language: raw.language || "fr",
        preferred_contact_method: raw.preferred_contact_method || null,
        internal_comment: raw.internal_comment || null,
        is_primary: roles.includes("primary"),
        active: raw.active === "on",
      };
    setBusy(true);
    try {
      const saved = await api().rpc("save_client_contact", {
        target_client_id: clientId,
        target_contact: payload,
        target_roles: roles,
      });
      closeDrawer();
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "contacts", currentState, true);
      if (documentMode && app().getState().draft?.client_id === clientId) {
        const d = app().getState().draft;
        d.contact_id = saved.id;
        await loadDocumentContext(d, currentState);
        global.PilozDocumentEditorV2?.renderEditor?.(currentState);
      }
      notify("Contact enregistré.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function toggleContact(clientId, contactId, active) {
    const data = detailEntry(clientId).tabs.get("contacts"),
      row = data?.rows.find((x) => x.id === contactId);
    if (!row) return;
    openContactModal(clientId, contactId);
    const form = document.getElementById("client-contact-form");
    if (form) form.elements.active.checked = active;
    await saveContact(clientId, contactId);
  }
  function openAddressModal(clientId, addressId = null, documentMode = false) {
    const rows = detailEntry(clientId).tabs.get("addresses")?.rows || [],
      row = rows.find((x) => x.id === addressId) || {};
    openDrawer(
      addressId ? "Modifier l’adresse" : "Nouvelle adresse",
      `<form id="client-address-form" class="client-form drawer-form" onsubmit="event.preventDefault();PilozClients.saveAddress('${clientId}','${addressId || ""}',${documentMode})"><div class="client-form-grid"><label><span>Libellé *</span><input name="label" required value="${esc(row.label || "")}"></label><label><span>Type</span><select name="address_type">${Object.entries(
        addressLabels,
      )
        .map(
          ([value, label]) =>
            `<option value="${value}" ${(row.address_type || "main") === value ? "selected" : ""}>${label}</option>`,
        )
        .join(
          "",
        )}</select></label><label><span>Nom du destinataire</span><input name="recipient_name" value="${esc(row.recipient_name || "")}"></label><label><span>Société</span><input name="company_name" value="${esc(row.company_name || "")}"></label><label class="full"><span>Adresse *</span><input name="address_line_1" required value="${esc(row.address_line_1 || "")}"></label><label class="full"><span>Ligne 2</span><input name="address_line_2" value="${esc(row.address_line_2 || "")}"></label><label class="full"><span>Complément</span><input name="complement" value="${esc(row.complement || "")}"></label><label><span>Code postal</span><input name="postal_code" value="${esc(row.postal_code || "")}"></label><label><span>Ville</span><input name="city" value="${esc(row.city || "")}"></label><label><span>Région</span><input name="region" value="${esc(row.region || "")}"></label><label><span>Pays</span><input name="country_code" value="${esc(row.country_code || "FR")}"></label><label><span>Téléphone</span><input name="phone_e164" value="${esc(row.phone_e164 || "")}"></label><label class="full"><span>Instructions</span><textarea name="instructions">${esc(row.instructions || "")}</textarea></label><fieldset class="full"><legend>Valeurs par défaut</legend><div class="client-role-grid"><label class="check"><input name="is_primary" type="checkbox" ${row.is_primary ? "checked" : ""}><span>Adresse principale</span></label><label class="check"><input name="is_default_billing" type="checkbox" ${row.is_default_billing ? "checked" : ""}><span>Facturation</span></label><label class="check"><input name="is_default_shipping" type="checkbox" ${row.is_default_shipping ? "checked" : ""}><span>Livraison</span></label><label class="check"><input name="is_default_service" type="checkbox" ${row.is_default_service ? "checked" : ""}><span>Intervention</span></label></div></fieldset><label class="check"><input name="active" type="checkbox" ${row.active !== false ? "checked" : ""}><span>Adresse active</span></label></div><footer>${button("Annuler", "PilozClients.closeDrawer()")}${button("Enregistrer", "", "btn-p", 'type="submit" data-client-save')}</footer></form>`,
      true,
    );
  }
  async function saveAddress(clientId, addressId = "", documentMode = false) {
    const form = document.getElementById("client-address-form");
    if (!form?.reportValidity()) return;
    const raw = formData("client-address-form"),
      payload = {
        id: addressId || null,
        label: raw.label,
        address_type: raw.address_type,
        recipient_name: raw.recipient_name || null,
        company_name: raw.company_name || null,
        address_line_1: raw.address_line_1,
        address_line_2: raw.address_line_2 || null,
        complement: raw.complement || null,
        postal_code: raw.postal_code || null,
        city: raw.city || null,
        region: raw.region || null,
        country_code: raw.country_code || "FR",
        phone_e164: raw.phone_e164 || null,
        instructions: raw.instructions || null,
        is_primary: raw.is_primary === "on",
        is_default_billing: raw.is_default_billing === "on",
        is_default_shipping: raw.is_default_shipping === "on",
        is_default_service: raw.is_default_service === "on",
        active: raw.active === "on",
      };
    setBusy(true);
    try {
      const saved = await api().rpc("save_client_address", {
        target_client_id: clientId,
        target_address: payload,
      });
      closeDrawer();
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "addresses", currentState, true);
      if (documentMode && app().getState().draft?.client_id === clientId) {
        const d = app().getState().draft;
        if (saved.is_default_billing || !d.billing_address_id)
          d.billing_address_id = saved.id;
        if (saved.is_default_shipping || !d.delivery_address_id)
          d.delivery_address_id = saved.id;
        await loadDocumentContext(d, currentState);
        global.PilozDocumentEditorV2?.renderEditor?.(currentState);
      }
      notify("Adresse enregistrée.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function toggleAddress(clientId, addressId, active) {
    const data = detailEntry(clientId).tabs.get("addresses"),
      row = data?.rows.find((x) => x.id === addressId);
    if (!row) return;
    openAddressModal(clientId, addressId);
    const form = document.getElementById("client-address-form");
    if (form) form.elements.active.checked = active;
    await saveAddress(clientId, addressId);
  }
  function openNoteModal(clientId, noteId = null) {
    const row =
      detailEntry(clientId)
        .tabs.get("notes")
        ?.rows.find((x) => x.id === noteId) || {};
    openDrawer(
      noteId ? "Modifier la note" : "Nouvelle note",
      `<form id="client-note-form" class="client-form drawer-form" onsubmit="event.preventDefault();PilozClients.saveNote('${clientId}','${noteId || ""}')"><label><span>Note interne *</span><textarea name="body" rows="9" required>${esc(row.body || "")}</textarea></label><fieldset><legend>Mentionner un utilisateur</legend><div class="client-role-grid">${(currentState.data.members || []).map((member) => `<label class="check"><input name="mentioned_user_ids" type="checkbox" value="${member.user_id}" ${(row.mentioned_user_ids || []).includes(member.user_id) ? "checked" : ""}><span>${esc(memberName(currentState, member.user_id))}</span></label>`).join("")}</div></fieldset><label class="check"><input name="pinned" type="checkbox" ${row.pinned ? "checked" : ""}><span>Épingler dans la synthèse</span></label><footer>${button("Annuler", "PilozClients.closeDrawer()")}${button("Enregistrer", "", "btn-p", 'type="submit" data-client-save')}</footer></form>`,
    );
  }
  async function saveNote(clientId, noteId = "") {
    const form = document.getElementById("client-note-form"),
      raw = formData("client-note-form"),
      payload = {
        company_id: currentState.companyId,
        client_id: clientId,
        body: raw.body?.trim(),
        pinned: raw.pinned === "on",
        mentioned_user_ids: [
          ...form.querySelectorAll('[name="mentioned_user_ids"]:checked'),
        ].map((input) => input.value),
        updated_by: global.PilozRuntime.session.user_id,
      };
    if (!payload.body) return;
    setBusy(true);
    try {
      noteId
        ? await api().update("client_notes", noteId, payload)
        : await api().insert("client_notes", payload);
      closeDrawer();
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "notes", currentState, true);
      notify("Note enregistrée.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function toggleNotePin(clientId, noteId, pinned) {
    try {
      await api().update("client_notes", noteId, {
        pinned,
        updated_by: global.PilozRuntime.session.user_id,
      });
      await loadTab(clientId, "notes", currentState, true);
      notify("Note mise à jour.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function deleteNote(clientId, noteId) {
    if (!confirm("Supprimer cette note interne ?")) return;
    try {
      await api().remove("client_notes", noteId);
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "notes", currentState, true);
      notify("Note supprimée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openActivityModal(clientId, contactId = "") {
    const contacts =
        detailEntry(clientId).tabs.get("contacts")?.rows ||
        (currentState.data.clientContacts || []).filter(
          (contact) =>
            contact.client_id === clientId && contact.active !== false,
        ),
      documents = (currentState.data.documents || []).filter(
        (document) => document.client_id === clientId,
      );
    openDrawer(
      "Nouvelle activité",
      `<form id="client-activity-form" class="client-form drawer-form" onsubmit="event.preventDefault();PilozClients.saveActivity('${clientId}')"><div class="client-form-grid"><label><span>Type</span><select name="activity_type"><option value="call">Appel</option><option value="email">E-mail</option><option value="meeting">Rendez-vous</option><option value="task">Tâche</option><option value="reminder">Relance</option><option value="demo">Démonstration</option><option value="quote_followup">Suivi de devis</option><option value="note">Note</option></select></label><label><span>Statut</span><select name="status"><option value="todo">À faire</option><option value="in_progress">En cours</option><option value="completed">Terminée</option></select></label><label class="full"><span>Titre *</span><input name="subject" required></label><label><span>Date prévue</span><input name="due_at" type="datetime-local"></label><label><span>Responsable</span><select name="assigned_user_id"><option value="">Moi</option>${(currentState.data.members || []).map((x) => `<option value="${x.user_id}">${esc(memberName(currentState, x.user_id))}</option>`).join("")}</select></label><label><span>Contact concerné</span><select name="contact_id"><option value="">Aucun contact</option>${contacts.map((contact) => `<option value="${contact.id}" ${contact.id === contactId ? "selected" : ""}>${esc([contact.first_name, contact.last_name].filter(Boolean).join(" "))}</option>`).join("")}</select></label><label><span>Document lié</span><select name="document_id"><option value="">Aucun document</option>${documents.map((document) => `<option value="${document.id}">${esc(`${document.number || "Brouillon"} · ${document.document_type === "quote" ? "Devis" : "Facture"}`)}</option>`).join("")}</select></label><label class="full"><span>Description</span><textarea name="description"></textarea></label></div><footer>${button("Annuler", "PilozClients.closeDrawer()")}${button("Créer", "", "btn-p", 'type="submit" data-client-save')}</footer></form>`,
    );
  }
  async function saveActivity(clientId) {
    const raw = formData("client-activity-form"),
      payload = {
        company_id: currentState.companyId,
        client_id: clientId,
        contact_id: raw.contact_id || null,
        document_id: raw.document_id || null,
        activity_type: raw.activity_type,
        subject: raw.subject?.trim(),
        description: raw.description || null,
        due_at: raw.due_at ? new Date(raw.due_at).toISOString() : null,
        scheduled_at: raw.due_at ? new Date(raw.due_at).toISOString() : null,
        status: raw.status || "todo",
        assigned_user_id:
          raw.assigned_user_id || global.PilozRuntime.session.user_id,
      };
    if (!payload.subject) return;
    setBusy(true);
    try {
      await api().insert("activities", payload);
      closeDrawer();
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "activities", currentState, true);
      notify("Activité créée.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function saveAccounting(clientId, confirmed = false) {
    const raw = formData("client-account-form"),
      auxiliaryAccount = String(raw.auxiliary_account || "").trim();
    if (!auxiliaryAccount) {
      notify("Renseignez le code auxiliaire du client.", "error");
      return;
    }
    setBusy(true);
    try {
      await api().rpc("assign_client_auxiliary_account", {
        target_client_id: clientId,
        target_assignment_mode: "manual",
        target_auxiliary_account: auxiliaryAccount,
        target_collective_account: null,
        target_effective_from: null,
        target_reason: null,
        target_confirm_existing_documents: confirmed,
      });
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "accounting", currentState, true);
      notify("Code auxiliaire enregistré.", "success");
    } catch (error) {
      if (
        /confirmation/i.test(error.message || "") &&
        !confirmed &&
        confirm(
          "Ce client possède déjà des documents. Confirmer le changement du compte auxiliaire ?",
        )
      )
        return saveAccounting(clientId, true);
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  async function changeClientStatus(id, status) {
    try {
      await api().update("clients", id, {
        customer_status: status,
        active: !["inactive", "archived"].includes(status),
      });
      invalidate(id);
      ui.directory = null;
      await app().refresh();
      openClient(id);
      notify("Statut du client mis à jour.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function showDuplicates(id) {
    const c = detailEntry(id).summary?.client;
    if (!c) return;
    try {
      const rows = await api().rpc("detect_client_duplicates", {
        target_company_id: currentState.companyId,
        target_client: c,
        target_exclude_id: id,
      });
      openDrawer(
        "Clients similaires",
        rows.length
          ? `<div class="client-duplicates">${rows.map((row) => `<article><div><b>${esc(row.name)}</b><small>${esc(row.matching_fields.join(", "))}</small></div>${button("Voir", `PilozClients.closeDrawer();PilozClients.openClient('${row.id}')`, "btn-ghost")}</article>`).join("")}</div>`
          : empty(
              "Aucun doublon détecté",
              "Aucun autre client ne partage les identifiants principaux.",
            ),
      );
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function uploadClientFile(clientId, file) {
    if (!file) return;
    const safe = String(file.name || "document").replace(
        /[^a-z0-9._-]+/gi,
        "-",
      ),
      path = `${currentState.companyId}/clients/${clientId}/${Date.now()}-${safe}`;
    try {
      await api().upload("company-files", path, file, false);
      await api().insert("client_documents", {
        company_id: currentState.companyId,
        client_id: clientId,
        file_name: file.name,
        document_type: "other",
        storage_path: path,
        mime_type: file.type || null,
        size_bytes: file.size,
        document_date: new Date().toISOString().slice(0, 10),
        internal_only: true,
      });
      invalidate(clientId);
      await loadSummary(clientId, currentState);
      await loadTab(clientId, "documents", currentState, true);
      notify("Document ajouté.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function downloadClientFile(id) {
    const route = routeParts(),
      clientId = route.path.split("/").pop(),
      row = detailEntry(clientId)
        .tabs.get("documents")
        ?.rows.find((x) => x.id === id);
    if (!row) return;
    try {
      const signed = await api().signedUrl(
        "company-files",
        row.storage_path,
        300,
      );
      const link = document.createElement("a");
      link.href = signed.signedURL || signed.signedUrl || signed.url;
      link.download = row.file_name;
      link.click();
    } catch (error) {
      notify(error.message, "error");
    }
  }

  function openClientCreator() {
    openDrawer(
      "Créer un client",
      `<form id="client-create-form" class="client-form drawer-form" onsubmit="event.preventDefault();PilozClients.saveNewClient()"><div class="client-kind-choice"><label><input type="radio" name="kind" value="company" checked onchange="PilozClients.toggleCreatorKind('company')"><span>Professionnel<small>Entreprise, association ou organisation</small></span></label><label><input type="radio" name="kind" value="person" onchange="PilozClients.toggleCreatorKind('person')"><span>Particulier<small>Personne physique</small></span></label></div><div class="client-form-grid"><div data-create-company><label class="full"><span>Raison sociale *</span><input name="legal_name"></label><label><span>SIREN</span><input name="siren"></label><label><span>SIRET</span><input name="siret"></label><label><span>Nom commercial</span><input name="trade_name"></label></div><div data-create-person hidden><label><span>Civilité</span><select name="civility"><option value="">—</option><option>M.</option><option>Mme</option></select></label><label><span>Prénom *</span><input name="first_name"></label><label><span>Nom *</span><input name="last_name"></label></div><label><span>E-mail</span><input name="email" type="email"></label><label><span>Téléphone</span><input name="phone_e164"></label><label class="full"><span>Adresse</span><input name="address_line_1"></label><label><span>Code postal</span><input name="postal_code"></label><label><span>Ville</span><input name="city"></label><label><span>Pays</span><input name="country_code" value="FR"></label><label><span>Statut</span><select name="customer_status"><option value="active">Actif</option><option value="prospect">Prospect</option><option value="watch">À surveiller</option></select></label></div><footer>${button("Annuler", "PilozClients.closeDrawer()")}${button("Créer le client", "", "btn-p", 'type="submit" data-client-save')}</footer></form>`,
      true,
    );
  }
  function toggleCreatorKind(kind) {
    document
      .querySelector("[data-create-company]")
      ?.toggleAttribute("hidden", kind !== "company");
    document
      .querySelector("[data-create-person]")
      ?.toggleAttribute("hidden", kind !== "person");
  }
  async function saveNewClient(force = false) {
    const raw = formData("client-create-form"),
      professional = raw.kind === "company",
      payload = {
        company_id: currentState.companyId,
        kind: raw.kind,
        customer_status: raw.customer_status || "active",
        legal_name: professional ? raw.legal_name?.trim() || null : null,
        trade_name: professional ? raw.trade_name || null : null,
        siren: professional ? raw.siren || null : null,
        siret: professional ? raw.siret || null : null,
        civility: professional ? null : raw.civility || null,
        first_name: professional ? null : raw.first_name?.trim() || null,
        last_name: professional ? null : raw.last_name?.trim() || null,
        email: raw.email?.trim().toLowerCase() || null,
        phone_e164: raw.phone_e164 || null,
        address_line_1: raw.address_line_1 || null,
        postal_code: raw.postal_code || null,
        city: raw.city || null,
        country_code: raw.country_code || "FR",
        active: true,
      };
    if (professional && !payload.legal_name) {
      notify("La raison sociale est obligatoire.", "error");
      return;
    }
    if (!professional && (!payload.first_name || !payload.last_name)) {
      notify("Le prénom et le nom sont obligatoires.", "error");
      return;
    }
    setBusy(true);
    try {
      if (!force) {
        const duplicates = await api().rpc("detect_client_duplicates", {
          target_company_id: currentState.companyId,
          target_client: payload,
          target_exclude_id: null,
        });
        if (
          duplicates.length &&
          !confirm(
            `Un client similaire existe déjà (${duplicates[0].name}). Continuer malgré tout ?`,
          )
        ) {
          setBusy(false);
          return;
        }
      }
      const saved = (await api().insert("clients", payload))[0];
      if (!saved?.id) throw new Error("Identifiant du client absent.");
      if (payload.address_line_1)
        await api().rpc("save_client_address", {
          target_client_id: saved.id,
          target_address: {
            label: "Adresse principale",
            address_type: "main",
            address_line_1: payload.address_line_1,
            postal_code: payload.postal_code,
            city: payload.city,
            country_code: payload.country_code,
            is_primary: true,
            is_default_billing: true,
            is_default_shipping: true,
            active: true,
          },
        });
      closeDrawer();
      ui.directory = null;
      await app().refresh();
      openClient(saved.id);
      notify("Client créé.", "success");
    } catch (error) {
      notify(error.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function loadDocumentContext(d, state) {
    if (!d?.client_id) {
      d.clientContacts = [];
      d.clientAddresses = [];
      return d;
    }
    const cid = encodeURIComponent(d.client_id),
      [contacts, addresses, prefs] = await Promise.all([
        queryPath("client_contacts", [
          `select=*`,
          `client_id=eq.${cid}`,
          `active=eq.true`,
          `order=is_primary.desc,created_at`,
        ]),
        queryPath("client_addresses", [
          `select=*`,
          `client_id=eq.${cid}`,
          `active=eq.true`,
          `order=is_primary.desc,created_at`,
        ]),
        queryPath("client_preferences", [`select=*`, `client_id=eq.${cid}`]),
      ]);
    d.clientContacts = contacts;
    d.clientAddresses = addresses;
    d.clientPreferences = prefs[0] || {};
    return d;
  }
  async function applyClientDefaults(d, clientId, state) {
    if (!d) return;
    d.client_id = clientId || "";
    if (!clientId) {
      d.contact_id = null;
      d.billing_address_id = null;
      d.delivery_address_id = null;
      d.clientContacts = [];
      d.clientAddresses = [];
      return d;
    }
    await loadDocumentContext(d, state);
    const pref = d.clientPreferences || {},
      client = (state.data.clients || []).find((x) => x.id === clientId) || {},
      primary =
        d.clientContacts.find((x) => x.id === pref.default_contact_id) ||
        d.clientContacts.find((x) => x.is_primary) ||
        d.clientContacts[0],
      billing =
        d.clientAddresses.find((x) => x.id === pref.billing_address_id) ||
        d.clientAddresses.find((x) => x.is_default_billing) ||
        d.clientAddresses.find((x) => x.is_primary),
      delivery =
        d.clientAddresses.find((x) => x.id === pref.shipping_address_id) ||
        d.clientAddresses.find((x) => x.is_default_shipping) ||
        d.clientAddresses.find((x) => x.id === pref.service_address_id) ||
        d.clientAddresses.find((x) => x.is_default_service);
    Object.assign(d, {
      contact_id: primary?.id || null,
      billing_address_id: billing?.id || null,
      delivery_address_id: delivery?.id || null,
      payment_method:
        pref.payment_method ||
        client.preferred_payment_method ||
        d.payment_method,
      payment_terms:
        pref.payment_terms || client.payment_terms || d.payment_terms,
      language: pref.language || client.language || d.language,
      currency: pref.currency || d.currency,
      discount_rate:
        Number(
          pref.usual_discount_rate ?? client.discount_rate ?? d.discount_rate,
        ) || 0,
      assigned_user_id:
        pref.assigned_user_id || client.assigned_user_id || d.assigned_user_id,
      template_id:
        d.document_type === "quote"
          ? pref.quote_template_id || d.template_id
          : pref.invoice_template_id || d.template_id,
      public_notes: pref.document_notes || d.public_notes,
    });
    return d;
  }
  function contextOptions(rows, selected, label) {
    return `<option value="">${esc(label)}</option>${rows.map((row) => `<option value="${row.id}" ${selected === row.id ? "selected" : ""}>${esc(row.label || [row.first_name, row.last_name].filter(Boolean).join(" ") || row.city || "Élément")}</option>`).join("")}`;
  }
  function enhanceDocumentContext() {
    const state = app()?.getState?.(),
      d = state?.draft;
    if (!d?.client_id || !document.querySelector(".document-v2")) return;
    const panel = document.querySelector(".document-v2-panel");
    if (panel && !panel.querySelector("[data-client-document-context]")) {
      const section = document.createElement("section");
      section.dataset.clientDocumentContext = "";
      section.className = "document-v2-client-context";
      section.innerHTML = `<h3>Destinataire et adresses</h3><label>Contact destinataire<select onchange="PilozClients.setDocumentContext('contact_id',this.value||null)">${contextOptions(d.clientContacts || [], d.contact_id, "Aucun contact")}</select></label><div class="document-context-actions"><button type="button" onclick="PilozClients.openContactModal('${d.client_id}',null,true)">+ Contact</button><button type="button" onclick="PilozClients.openClient('${d.client_id}','contacts')">Gérer</button></div><label>Adresse de facturation<select onchange="PilozClients.setDocumentContext('billing_address_id',this.value||null)">${contextOptions(d.clientAddresses || [], d.billing_address_id, "Adresse historique")}</select></label><label>Livraison / intervention<select onchange="PilozClients.setDocumentContext('delivery_address_id',this.value||null)">${contextOptions(d.clientAddresses || [], d.delivery_address_id, "Non affichée")}</select></label><div class="document-context-actions"><button type="button" onclick="PilozClients.useBillingForDelivery()">Même adresse</button><button type="button" onclick="PilozClients.openAddressModal('${d.client_id}',null,true)">+ Adresse</button><button type="button" onclick="PilozClients.openClient('${d.client_id}','addresses')">Gérer</button></div>`;
      panel.insertBefore(section, panel.children[1] || null);
    }
    if (
      lastDocumentClient !== d.client_id ||
      (!(d.clientContacts || []).length && !(d.clientAddresses || []).length)
    ) {
      lastDocumentClient = d.client_id;
      loadDocumentContext(d, state)
        .then(() => global.PilozDocumentEditorV2?.renderEditor?.(state))
        .catch((error) => notify(error.message, "error"));
    }
  }
  function setDocumentContext(field, value) {
    const state = app().getState(),
      d = state.draft;
    if (!d) return;
    d[field] = value;
    global.PilozDocumentEditorV2?.renderEditor?.(state);
  }
  function useBillingForDelivery() {
    const state = app().getState(),
      draft = state.draft;
    if (!draft) return;
    draft.delivery_address_id = draft.billing_address_id || null;
    global.PilozDocumentEditorV2?.renderEditor?.(state);
  }
  function wrapDocumentSave() {
    if (saveWrapped || !app()?.saveDocument) return;
    saveWrapped = true;
    const original = app().saveDocument;
    app().saveDocument = async function (...args) {
      const before = app().getState().draft,
        context = before
          ? {
              client_id: before.client_id,
              contact_id: before.contact_id || null,
              billing_address_id: before.billing_address_id || null,
              delivery_address_id: before.delivery_address_id || null,
            }
          : null,
        id = await original(...args);
      if (!id || !context?.client_id) return id;
      try {
        const saved = await api().rpc("save_document_client_context", {
            target_document_id: id,
            target_contact_id: context.contact_id,
            target_billing_address_id: context.billing_address_id,
            target_delivery_address_id: context.delivery_address_id,
          }),
          state = app().getState(),
          doc = (state.data.documents || []).find((x) => x.id === id);
        if (doc)
          Object.assign(doc, {
            contact_id: context.contact_id,
            billing_address_id: context.billing_address_id,
            delivery_address_id: context.delivery_address_id,
            snapshot_id: saved?.snapshot_id || doc.snapshot_id,
          });
        if (state.draft?.id === id)
          Object.assign(state.draft, {
            contact_id: context.contact_id,
            billing_address_id: context.billing_address_id,
            delivery_address_id: context.delivery_address_id,
          });
        return id;
      } catch (error) {
        console.error("[PILOZ Clients] Contexte du document non enregistré", {
          code: error?.code || "",
          message: error?.message || String(error),
        });
        notify(
          "Le brouillon est conservé, mais le contact ou les adresses n’ont pas pu être enregistrés.",
          "error",
        );
        throw error;
      }
    };
  }

  function enhanceClientListControls() {
    if (routeParts().path !== "sales/clients") return;
    const toolbar = document.querySelector(".client-toolbar");
    if (toolbar && !toolbar.querySelector("[data-client-sort]")) {
      const sort = document.createElement("select");
      sort.dataset.clientSort = "";
      sort.setAttribute("aria-label", "Trier les clients");
      sort.innerHTML =
        '<option value="name:asc">Nom A → Z</option><option value="name:desc">Nom Z → A</option><option value="invoiced:desc">Plus facturés</option><option value="outstanding:desc">Solde le plus élevé</option><option value="last_activity:desc">Activité récente</option>';
      sort.value = `${ui.sort}:${ui.direction}`;
      sort.onchange = () => setSort(sort.value);
      toolbar.insertBefore(
        sort,
        toolbar.querySelector(".client-column-picker"),
      );
    }
    const advanced = document.querySelector(".client-advanced-filters");
    if (advanced && !advanced.querySelector("[data-client-extra-filters]"))
      advanced.insertAdjacentHTML(
        "beforeend",
        `<div class="client-extra-filters" data-client-extra-filters><label><span>Tag</span><input value="${esc(ui.tag)}" placeholder="VIP, chantier…" oninput="PilozClients.setListFilter('tag',this.value)"></label><label><span>Sans activité depuis</span><select onchange="PilozClients.setListFilter('inactiveDays',this.value)"><option value="">Toute activité</option><option value="30" ${ui.inactiveDays === "30" ? "selected" : ""}>30 jours</option><option value="90" ${ui.inactiveDays === "90" ? "selected" : ""}>90 jours</option><option value="180" ${ui.inactiveDays === "180" ? "selected" : ""}>180 jours</option></select></label><label class="check"><input type="checkbox" ${ui.overdue ? "checked" : ""} onchange="PilozClients.setBooleanFilter('overdue',this.checked)"><span>Factures en retard</span></label><label class="check"><input type="checkbox" ${ui.debtor ? "checked" : ""} onchange="PilozClients.setBooleanFilter('debtor',this.checked)"><span>Solde débiteur</span></label></div>`,
      );
  }
  function accountSettingsMarkup(settings = {}) {
    return `<section class="phase1-card client-account-settings-card" data-customer-account-settings><h2>Comptes clients</h2><p class="modern-card-desc">Définissez la génération automatique et le contrôle des comptes auxiliaires clients.</p><form id="customer-account-settings-form" class="client-form" onsubmit="event.preventDefault();PilozClients.saveAccountSettings()"><div class="client-form-grid"><label><span>Compte collectif par défaut</span><input name="default_collective_account" value="${esc(settings.default_collective_account || "411000")}"></label><label><span>Préfixe</span><input name="prefix" value="${esc(settings.prefix || "CLI")}"></label><label><span>Longueur du numéro</span><input name="padding" type="number" min="1" max="24" value="${Number(settings.padding) || 6}"></label><label><span>Prochain numéro</span><input name="next_number" type="number" min="1" value="${Number(settings.next_number) || 1}"></label><label><span>Format</span><select name="account_format"><option value="prefix_number">Préfixe + numéro</option><option value="c_number" ${settings.account_format === "c_number" ? "selected" : ""}>C + numéro</option><option value="initial_number" ${settings.account_format === "initial_number" ? "selected" : ""}>Initiale + numéro</option><option value="siren" ${settings.account_format === "siren" ? "selected" : ""}>SIREN</option><option value="custom" ${settings.account_format === "custom" ? "selected" : ""}>Personnalisé</option></select></label><label><span>Format personnalisé</span><input name="custom_pattern" value="${esc(settings.custom_pattern || "{PREFIX}{NUMBER}")}"></label><label><span>Compte des professionnels</span><input name="professional_collective_account" value="${esc(settings.professional_collective_account || "")}"></label><label><span>Compte des particuliers</span><input name="individual_collective_account" value="${esc(settings.individual_collective_account || "")}"></label><label class="check"><input name="automatic_generation" type="checkbox" ${settings.automatic_generation !== false ? "checked" : ""}><span>Génération automatique</span></label><label class="check"><input name="allow_manual" type="checkbox" ${settings.allow_manual !== false ? "checked" : ""}><span>Autoriser la saisie manuelle</span></label><label class="check"><input name="enforce_uniqueness" type="checkbox" ${settings.enforce_uniqueness !== false ? "checked" : ""}><span>Vérifier l’unicité</span></label><label class="check"><input name="manage_inactive" type="checkbox" ${settings.manage_inactive !== false ? "checked" : ""}><span>Gérer les comptes inactifs</span></label></div><div class="client-account-preview"><span>Prochain compte proposé</span><b>${esc(settings.prefix || "CLI")}${String(Number(settings.next_number) || 1).padStart(Number(settings.padding) || 6, "0")}</b></div><div class="modern-form-actions">${button("Enregistrer les comptes clients", "", "btn-p", 'type="submit" data-client-save')}</div></form></section>`;
  }
  async function enhanceAccountSettings() {
    if (
      routeParts().path !== "settings/accounting" ||
      document.querySelector("[data-customer-account-settings]") ||
      !currentState?.companyId
    )
      return;
    const grid = document.querySelector(".modern-settings-grid");
    if (!grid) return;
    const pending = document.createElement("section");
    pending.className = "phase1-card";
    pending.dataset.customerAccountSettings = "loading";
    pending.innerHTML =
      '<h2>Comptes clients</h2><p class="modern-card-desc">Chargement des paramètres…</p>';
    grid.appendChild(pending);
    try {
      const rows = await queryPath("company_customer_account_settings", [
        `select=*`,
        `company_id=eq.${encodeURIComponent(currentState.companyId)}`,
        `limit=1`,
      ]);
      if (routeParts().path !== "settings/accounting") return;
      pending.outerHTML = accountSettingsMarkup(rows[0] || {});
    } catch (error) {
      pending.innerHTML = `<h2>Comptes clients</h2><p class="client-error">${esc(error.message || "Chargement impossible.")}</p>`;
    }
  }
  function renderRoute(raw, state) {
    currentState = state;
    const { path, query } = routeParts(raw);
    if (path === "sales/clients") {
      renderList(state);
      return true;
    }
    if (path.startsWith("sales/clients/")) {
      const id = path.slice("sales/clients/".length);
      renderDetail(id, state, query.get("tab") || "summary");
      return true;
    }
    return false;
  }
  const observer = new MutationObserver(() => {
    const path = routeParts().path;
    if (path === "document-editor") queueMicrotask(enhanceDocumentContext);
    if (path === "sales/clients") queueMicrotask(enhanceClientListControls);
  });
  const main = document.getElementById("main");
  if (main) observer.observe(main, { childList: true, subtree: false });
  wrapDocumentSave();
  global.PilozClients = {
    ui,
    renderRoute,
    renderList,
    setListFilter,
    setBooleanFilter,
    setSort,
    setSearch,
    setPage,
    toggleSelection,
    toggleAll,
    toggleAdvanced,
    toggleColumn,
    retryDirectory,
    clearSelection,
    exportCsv,
    openClient,
    setTab,
    reloadTab,
    closeDrawer,
    openClientCreator,
    toggleCreatorKind,
    saveNewClient,
    saveCoordinates,
    toggleCoordinateKind,
    savePreferences,
    openContactModal,
    saveContact,
    toggleContact,
    openAddressModal,
    saveAddress,
    toggleAddress,
    openNoteModal,
    saveNote,
    toggleNotePin,
    deleteNote,
    openActivityModal,
    saveActivity,
    saveAccounting,
    changeClientStatus,
    showDuplicates,
    uploadClientFile,
    downloadClientFile,
    loadDocumentContext,
    applyClientDefaults,
    enhanceDocumentContext,
    enhanceClientListControls,
    setDocumentContext,
    useBillingForDelivery,
  };
})(window);
