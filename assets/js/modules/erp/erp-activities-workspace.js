(function activitiesWorkspace(global) {
  "use strict";
  // Register the workspace even while a legacy module is still finishing its
  // setup. Runtime dependencies are resolved only when an action is executed.
  const crm = global.PilozCRM || (global.PilozCRM = {}),
    api = () => global.PilozERP,
    app = () => global.PilozApp;
  const ui = {
    view: "list",
    calendarMode: "week",
    quick: "today",
    search: "",
    status: "",
    typeId: "",
    owner: "",
    team: "",
    savedFilterId: "",
    page: 1,
    pageSize: 50,
    density: "comfortable",
    showMetrics: true,
    visibleColumns: [
      "type",
      "subject",
      "relation",
      "owner",
      "date",
      "duration",
      "priority",
      "status",
    ],
    sortKey: "activity_at",
    sortDirection: "asc",
    preferencesLoaded: false,
    advancedFilters: false,
    request: 0,
    data: null,
    selected: new Set(),
    detail: null,
    connections: [],
    calendarDate: new Date(),
    busy: false,
    searchTimer: null,
    relationTimers: new Map(),
  };
  const defaultColumns = [
    "type",
    "subject",
    "relation",
    "owner",
    "date",
    "duration",
    "priority",
    "status",
  ];
  const columnLabels = {
    type: "Type",
    subject: "Activité",
    relation: "Relation",
    owner: "Responsable",
    date: "Date",
    duration: "Durée",
    priority: "Priorité",
    status: "Statut",
  };
  const esc = (value) =>
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
  const attr = (value) => esc(value).replace(/`/g, "&#96;");
  const route = () =>
    String(location.hash || "#dashboard")
      .slice(1)
      .split("?")[0];
  const currentUser = () => global.PilozRuntime?.session?.user_id || "";
  const state = () => app().getState();
  const members = () => state().data.members || [];
  const memberName = (id) => {
    const member = members().find((row) => row.user_id === id),
      profile = (state().data.preferences || []).find(
        (row) => row.user_id === id,
      );
    return (
      profile?.display_name ||
      [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") ||
      member?.display_name ||
      (id === currentUser() ? "Moi" : "Non attribué")
    );
  };
  const money = (value) =>
    new Intl.NumberFormat("fr-FR", {
      style: "currency",
      currency: "EUR",
    }).format(Number(value) || 0);
  const formatDate = (value) =>
    value
      ? new Intl.DateTimeFormat("fr-FR", { dateStyle: "medium" }).format(
          new Date(value),
        )
      : "—";
  const formatTime = (value) =>
    value
      ? new Intl.DateTimeFormat("fr-FR", {
          hour: "2-digit",
          minute: "2-digit",
        }).format(new Date(value))
      : "—";
  const formatDateTime = (value) =>
    value
      ? new Intl.DateTimeFormat("fr-FR", {
          dateStyle: "short",
          timeStyle: "short",
        }).format(new Date(value))
      : "—";
  const localInput = (value) => {
    if (!value) return "";
    const date = new Date(value);
    return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
      .toISOString()
      .slice(0, 16);
  };
  const iso = (value) => (value ? new Date(value).toISOString() : null);
  const notify = (message, type = "info") => global.toast?.(message, type);
  const errorMessage = (
    error,
    fallback = "L’opération n’a pas pu aboutir.",
  ) => {
    console.error("[PILOZ Activités]", {
      code: error?.code || "",
      status: error?.status || 0,
      message: error?.message || String(error),
    });
    const map = {
      activities_forbidden: "Vous n’avez pas accès aux activités.",
      activity_forbidden: "Vous ne pouvez pas modifier cette activité.",
      activity_not_found: "Cette activité est introuvable ou privée.",
      activity_relation_invalid:
        "Une relation sélectionnée n’est plus accessible.",
      activity_assignment_forbidden:
        "Ce responsable ne fait pas partie de votre périmètre.",
      activity_subject_required: "Le titre est obligatoire.",
    };
    return map[error?.message] || error?.message || fallback;
  };
  const missingRpc = (error, name) => {
    const message =
      `${error?.message || ""} ${error?.details || ""}`.toLowerCase();
    return (
      ["42883", "pgrst202"].includes(String(error?.code || "").toLowerCase()) ||
      (message.includes(name.toLowerCase()) &&
        (message.includes("does not exist") || message.includes("not found")))
    );
  };
  const statusLabels = {
    draft: "Brouillon",
    todo: "À faire",
    scheduled: "Planifiée",
    in_progress: "En cours",
    completed: "Terminée",
    cancelled: "Annulée",
    missed: "Manquée",
    postponed: "Reportée",
  };
  const priorityLabels = {
    low: "Basse",
    normal: "Normale",
    high: "Haute",
    urgent: "Urgente",
  };
  const confidentialityLabels = {
    standard: "Standard",
    company: "Entreprise",
    team: "Équipe",
    private: "Privée",
  };
  const sourceLabels = {
    manual: "Manuelle",
    gmail: "Gmail",
    outlook: "Outlook",
    google_calendar: "Google Agenda",
    microsoft_calendar: "Outlook Calendar",
    automation: "Automatisation",
    conversion: "Conversion",
    api: "API",
    pilo: "Pilo",
    system: "Système",
  };
  const typeIcon = (slug) =>
    ({
      call: "☎",
      email: "✉",
      meeting: "◫",
      video: "▣",
      task: "✓",
      reminder: "↻",
      note: "≡",
      demo: "▶",
      presentation: "▤",
      proposal: "€",
      quote_followup: "⌁",
      invoice_followup: "⌁",
      payment_followup: "€",
      administrative: "◇",
      visit: "⌖",
      event: "◉",
    })[slug] || "•";
  const activityDate = (row) =>
    row.starts_at || row.due_at || row.scheduled_at || row.created_at;
  const isOverdue = (row) =>
    !["completed", "cancelled"].includes(row.status) &&
    activityDate(row) &&
    new Date(activityDate(row)) < new Date();
  const linkedLabel = (row) =>
    row.entity_name ||
    row.opportunity_name ||
    row.document_number ||
    "Aucune relation";
  const button = (label, action, tone = "", extra = "") =>
    `<button type="button" class="aw-button ${tone}" onclick="${action}" ${extra}>${esc(label)}</button>`;

  function closeModal() {
    document.getElementById("activity-workspace-modal")?.remove();
    document.body.classList.remove("aw-modal-open");
  }
  function modal(title, subtitle, body, footer = "", wide = false) {
    closeModal();
    const layer = document.createElement("div");
    layer.id = "activity-workspace-modal";
    layer.className = "aw-modal-layer";
    layer.addEventListener("mousedown", (event) => {
      if (event.target === layer) closeModal();
    });
    layer.innerHTML = `<section class="aw-modal ${wide ? "wide" : ""}" role="dialog" aria-modal="true" aria-labelledby="aw-modal-title"><header><div><h2 id="aw-modal-title">${esc(title)}</h2><p>${esc(subtitle || "")}</p></div><button type="button" class="aw-icon-button" onclick="PilozCRM.closeActivitiesModal()" aria-label="Fermer">×</button></header><div class="aw-modal-body">${body}</div><footer>${footer}</footer></section>`;
    document.body.appendChild(layer);
    document.body.classList.add("aw-modal-open");
    setTimeout(
      () =>
        layer
          .querySelector("input:not([type=hidden]),select,textarea,button")
          ?.focus(),
      30,
    );
  }

  function queryWindow() {
    const date = new Date(ui.calendarDate),
      start = new Date(date),
      end = new Date(date);
    if (ui.view !== "agenda") return { start: null, end: null };
    if (ui.calendarMode === "day") {
      start.setHours(0, 0, 0, 0);
      end.setTime(start.getTime() + 86400000);
    } else if (ui.calendarMode === "month") {
      start.setDate(1);
      start.setHours(0, 0, 0, 0);
      end.setMonth(start.getMonth() + 1, 1);
      end.setHours(0, 0, 0, 0);
    } else {
      const day = (start.getDay() + 6) % 7;
      start.setDate(start.getDate() - day);
      start.setHours(0, 0, 0, 0);
      end.setTime(start.getTime() + 7 * 86400000);
    }
    return { start: start.toISOString(), end: end.toISOString() };
  }
  async function loadConnections() {
    try {
      const companyId = state().companyId,
        userId = currentUser();
      ui.connections = await api().query(
        "external_connections",
        `select=id,provider,display_name,account_email,status,settings,last_successful_sync_at&company_id=eq.${encodeURIComponent(companyId)}&user_id=eq.${encodeURIComponent(userId)}&status=eq.connected&provider=in.(google_calendar,microsoft_calendar)`,
      );
    } catch (error) {
      ui.connections = [];
      console.warn("[PILOZ Activités] Connexions agenda indisponibles", {
        code: error?.code || "",
        status: error?.status || 0,
      });
    }
  }
  function applyPreferences(preferences = {}) {
    if (!preferences || !Object.keys(preferences).length) return false;
    const firstLoad = !ui.preferencesLoaded,
      nextView = preferences.default_view || "list";
    const nextColumns = Array.isArray(preferences.visible_columns)
      ? preferences.visible_columns.filter((key) => columnLabels[key])
      : defaultColumns;
    const changed =
      Number(preferences.page_size || 50) !== ui.pageSize ||
      (preferences.density || "comfortable") !== ui.density ||
      Boolean(preferences.show_metrics ?? true) !== ui.showMetrics ||
      (preferences.sort_key || "activity_at") !== ui.sortKey ||
      (preferences.sort_direction || "asc") !== ui.sortDirection ||
      JSON.stringify(nextColumns) !== JSON.stringify(ui.visibleColumns) ||
      (firstLoad && nextView !== ui.view);
    ui.pageSize = Number(preferences.page_size) || 50;
    ui.density = preferences.density || "comfortable";
    ui.showMetrics = Boolean(preferences.show_metrics ?? true);
    ui.visibleColumns = nextColumns.length ? nextColumns : defaultColumns;
    ui.sortKey = preferences.sort_key || "activity_at";
    ui.sortDirection = preferences.sort_direction || "asc";
    if (firstLoad) ui.view = nextView;
    ui.preferencesLoaded = true;
    return changed;
  }
  async function load(force = false) {
    const token = ++ui.request,
      main = document.getElementById("main");
    if (main && !ui.data)
      main.innerHTML =
        '<main class="aw-shell"><div class="aw-loading" role="status"><i></i><span>Chargement des activités…</span></div></main>';
    else main?.querySelector(".aw-shell")?.classList.add("is-refreshing");
    try {
      if (force || !ui.connections.length) await loadConnections();
      const range = queryWindow(),
        view =
          ui.view === "mine" ? "my" : ui.view === "team" ? "team" : ui.view;
      const payload = {
        target_view: view,
        target_quick_filter: ui.view === "agenda" ? "all" : ui.quick,
        target_search: ui.search || null,
        target_statuses: ui.status ? [ui.status] : null,
        target_type_ids: ui.typeId ? [ui.typeId] : null,
        target_owner: ui.owner || null,
        target_team: ui.team || null,
        target_start: range.start,
        target_end: range.end,
        target_include_archived: ui.quick === "archived",
        target_page: ui.page,
        target_page_size: ui.pageSize,
        target_sort_key: ui.sortKey,
        target_sort_direction: ui.sortDirection,
      };
      let data;
      try {
        data = await api().rpc("get_activity_workspace_v4", payload);
      } catch (error) {
        if (!missingRpc(error, "get_activity_workspace_v4")) throw error;
        const { target_sort_key, target_sort_direction, ...legacyPayload } =
          payload;
        data = await api().rpc("get_activity_workspace_v3", legacyPayload);
      }
      if (
        token !== ui.request ||
        !["crm/activities", "activities"].includes(route())
      )
        return;
      const preferencesChanged = applyPreferences(data?.preferences || {});
      ui.data = data || {};
      if (preferencesChanged && ui.preferencesLoaded && !force) {
        ui.page = 1;
        return load(true);
      }
      const lastPage = Math.max(
        1,
        Math.ceil((Number(ui.data.total) || 0) / ui.pageSize),
      );
      if (ui.page > lastPage) {
        ui.page = lastPage;
        return load(true);
      }
      render();
    } catch (error) {
      if (token !== ui.request) return;
      if (main)
        main.innerHTML = `<main class="aw-shell"><section class="aw-error"><h2>Impossible de charger les activités</h2><p>${esc(errorMessage(error))}</p>${button("Réessayer", "PilozCRM.loadActivitiesWorkspace(true)", "primary")}</section></main>`;
    }
  }

  function header() {
    const connected = ui.connections.length
      ? `<span class="aw-connected" title="Synchronisation réelle configurée">● ${ui.connections.length} agenda${ui.connections.length > 1 ? "s" : ""} connecté${ui.connections.length > 1 ? "s" : ""}</span>`
      : "";
    const total = Number(ui.data?.total) || 0;
    return `<header class="aw-page-head"><div><p class="aw-kicker">SUIVI COMMERCIAL</p><div class="aw-title-line"><h1>Activités</h1><span>${total.toLocaleString("fr-FR")}</span></div><p>Le poste de travail de l’équipe pour planifier, prioriser et tracer chaque action.</p></div><div class="aw-head-actions">${connected}${button("Personnaliser", "PilozCRM.openActivityWorkspaceSettings()", "ghost")}${ui.data?.permissions?.configure ? button("Types d’activité", "PilozCRM.openActivityTypes()", "ghost") : ""}${ui.data?.permissions?.write ? button("Noter un appel", "PilozCRM.openQuickCallWorkspace()", "ghost") : ""}${ui.data?.permissions?.write ? button("Nouvelle activité", "PilozCRM.openActivityForm()", "primary") : ""}</div></header>`;
  }
  function metric(label, value, quick, tone = "") {
    return `<button type="button" class="aw-metric ${tone} ${ui.quick === quick ? "active" : ""}" onclick="PilozCRM.setActivityQuick('${quick}')"><span>${esc(label)}</span><strong>${(Number(value) || 0).toLocaleString("fr-FR")}</strong></button>`;
  }
  function metrics() {
    const c = ui.data?.counts || {};
    if (!ui.showMetrics) return "";
    return `<section class="aw-metrics" aria-label="Indicateurs">${metric("Aujourd’hui", c.today, "today")}${metric("En retard", c.overdue, "overdue", "danger")}${metric("Cette semaine", c.week, "week")}${metric("Terminées cette semaine", c.completed_week, "completed", "success")}${metric("Appels ouverts", c.calls, "all")}${metric("Relances à venir", c.reminders, "upcoming")}${metric("Non attribuées", c.unassigned, "unassigned", "warning")}</section>`;
  }
  function option(value, label, selected) {
    return `<option value="${attr(value)}" ${String(value) === String(selected) ? "selected" : ""}>${esc(label)}</option>`;
  }
  function ownerOptions(selected, blank = "Tous les responsables") {
    return (
      option("", blank, selected) +
      members()
        .filter((row) => row.status !== "removed")
        .map((row) => option(row.user_id, memberName(row.user_id), selected))
        .join("")
    );
  }
  function toolbar() {
    const types = ui.data?.types || [],
      filters = ui.data?.saved_filters || [];
    return `<section class="aw-toolbar"><div class="aw-toolbar-top"><div class="aw-view-tabs" role="tablist">${[
      ["list", "Liste"],
      ["agenda", "Agenda"],
      ["timeline", "Chronologie"],
      ["mine", "Mes activités"],
      ["team", "Équipe"],
    ]
      .filter(
        ([id]) =>
          id !== "team" ||
          ui.data?.permissions?.view_team ||
          ui.data?.permissions?.view_all,
      )
      .map(
        ([id, label]) =>
          `<button role="tab" aria-selected="${ui.view === id}" class="${ui.view === id ? "active" : ""}" onclick="PilozCRM.setActivityWorkspaceView('${id}')">${label}</button>`,
      )
      .join(
        "",
      )}</div><div class="aw-toolbar-tools">${button(ui.advancedFilters ? "Masquer les filtres" : "Plus de filtres", "PilozCRM.toggleActivityAdvancedFilters()", "ghost")}${button("Colonnes et affichage", "PilozCRM.openActivityWorkspaceSettings()", "ghost")}</div></div><div class="aw-filters"><label class="aw-search"><span aria-hidden="true">⌕</span><input value="${attr(ui.search)}" placeholder="Sujet, client, contact, opportunité ou document…" aria-label="Rechercher" oninput="PilozCRM.searchActivities(this.value)"></label><select aria-label="Type" onchange="PilozCRM.setActivityType(this.value)">${option("", "Tous les types", ui.typeId)}${types.map((row) => option(row.id, row.label, ui.typeId)).join("")}</select><select aria-label="Statut" onchange="PilozCRM.setActivityStatus(this.value)">${option("", "Tous les statuts", ui.status)}${Object.entries(
      statusLabels,
    )
      .map(([id, label]) => option(id, label, ui.status))
      .join(
        "",
      )}</select><select aria-label="Responsable" onchange="PilozCRM.setActivityOwner(this.value)">${ownerOptions(ui.owner)}</select>${ui.advancedFilters ? `<select aria-label="Vue enregistrée" onchange="PilozCRM.applyActivitySavedFilter(this.value)">${option("", "Vues enregistrées", ui.savedFilterId)}${filters.map((row) => option(row.id, row.name, ui.savedFilterId)).join("")}</select>${button("Enregistrer la vue", "PilozCRM.openSaveActivityFilter()", "ghost")}${ui.savedFilterId ? button("Supprimer", "PilozCRM.deleteActivitySavedFilter()", "danger") : ""}` : ""}</div>${ui.selected.size ? `<div class="aw-bulk" role="toolbar" aria-label="Actions groupées"><b>${ui.selected.size.toLocaleString("fr-FR")} sélectionnée(s)</b>${button("Terminer", 'PilozCRM.bulkActivityAction("status",{status:"completed"})', "success")}${button("Changer le statut", "PilozCRM.openBulkActivityStatus()", "ghost")}${button("Attribuer", "PilozCRM.openBulkActivityAssign()", "ghost")}${button("Reporter", "PilozCRM.openBulkReschedule()", "ghost")}${button("Archiver", 'PilozCRM.bulkActivityAction("archive",{})', "danger")}</div>` : ""}</section>`;
  }
  function quickFilters() {
    if (ui.view === "agenda") return calendarToolbar();
    const c = ui.data?.counts || {};
    return `<nav class="aw-quick" aria-label="Vues rapides">${[
      ["today", "Aujourd’hui", c.today],
      ["overdue", "En retard", c.overdue],
      ["upcoming", "À venir", ""],
      ["week", "Cette semaine", c.week],
      ["unassigned", "Non attribuées", c.unassigned],
      ["completed", "Terminées", c.completed_week],
      ["cancelled", "Annulées", ""],
      ["archived", "Archivées", c.archived],
      ["all", "Toutes", ""],
    ]
      .map(
        ([id, label, count]) =>
          `<button class="${ui.quick === id ? "active" : ""}" onclick="PilozCRM.setActivityQuick('${id}')">${label}${count !== "" && count != null ? `<span>${Number(count).toLocaleString("fr-FR")}</span>` : ""}</button>`,
      )
      .join("")}</nav>`;
  }
  function activityType(row) {
    return `<span class="aw-type" style="--aw-type:${attr(row.type_color || "#14b8a6")}"><i>${typeIcon(row.activity_type)}</i><span>${esc(row.type_label || row.activity_type || "Activité")}</span></span>`;
  }
  function statusBadge(row) {
    return `<span class="aw-status ${attr(row.status)} ${isOverdue(row) ? "overdue" : ""}">${isOverdue(row) ? "En retard" : esc(statusLabels[row.status] || row.status)}</span>`;
  }
  function priorityBadge(value) {
    return `<span class="aw-priority ${attr(value || "normal")}">${esc(priorityLabels[value] || value || "Normale")}</span>`;
  }
  function visible(key) {
    return ui.visibleColumns.includes(key);
  }
  function sortableHeader(key, label) {
    const active = ui.sortKey === key;
    return `<button class="aw-sort ${active ? "active" : ""}" onclick="PilozCRM.sortActivities('${key}')">${esc(label)}<span>${active ? (ui.sortDirection === "asc" ? "↑" : "↓") : "↕"}</span></button>`;
  }
  function listView() {
    const rows = ui.data?.rows || [];
    if (!rows.length) return empty();
    return `<section class="aw-table-wrap ${ui.density === "compact" ? "compact" : ""}"><table class="aw-table"><thead><tr><th class="aw-select-column"><input type="checkbox" aria-label="Sélectionner la page" onchange="PilozCRM.selectAllActivities(this.checked)"></th>${visible("type") ? "<th>Type</th>" : ""}${visible("subject") ? `<th>${sortableHeader("subject", "Activité")}</th>` : ""}${visible("relation") ? "<th>Relation</th>" : ""}${visible("owner") ? `<th>${sortableHeader("owner", "Responsable")}</th>` : ""}${visible("date") ? `<th>${sortableHeader("activity_at", "Date")}</th>` : ""}${visible("duration") ? "<th>Durée</th>" : ""}${visible("priority") ? `<th>${sortableHeader("priority", "Priorité")}</th>` : ""}${visible("status") ? `<th>${sortableHeader("status", "Statut")}</th>` : ""}<th class="aw-actions-column">Actions</th></tr></thead><tbody>${rows.map((row) => `<tr class="${isOverdue(row) ? "is-overdue" : ""}" ondblclick="PilozCRM.openActivityDetail('${row.id}')"><td class="aw-select-column"><input type="checkbox" aria-label="Sélectionner ${attr(row.subject)}" ${ui.selected.has(row.id) ? "checked" : ""} onchange="PilozCRM.selectActivity('${row.id}',this.checked)"></td>${visible("type") ? `<td>${activityType(row)}</td>` : ""}${visible("subject") ? `<td><button class="aw-title-link" onclick="PilozCRM.openActivityDetail('${row.id}')"><b>${esc(row.subject)}</b><small>${esc(row.summary || row.description || "")}</small></button></td>` : ""}${visible("relation") ? `<td><span class="aw-related">${esc(linkedLabel(row))}${row.contact_name ? `<small>${esc(row.contact_name)}</small>` : ""}</span></td>` : ""}${visible("owner") ? `<td>${esc(memberName(row.assigned_user_id))}</td>` : ""}${visible("date") ? `<td><b>${formatDate(activityDate(row))}</b><small>${row.all_day ? "Journée entière" : formatTime(activityDate(row))}</small></td>` : ""}${visible("duration") ? `<td>${Number(row.duration_minutes) || 0} min</td>` : ""}${visible("priority") ? `<td>${priorityBadge(row.priority)}</td>` : ""}${visible("status") ? `<td>${statusBadge(row)}</td>` : ""}<td class="aw-actions-column"><div class="aw-row-actions"><button onclick="PilozCRM.openActivityDetail('${row.id}')" aria-label="Ouvrir">↗</button>${ui.data?.permissions?.write ? `<button onclick="PilozCRM.openActivityForm('${row.id}')" aria-label="Modifier">✎</button>` : ""}</div></td></tr>`).join("")}</tbody></table></section>${pagination()}`;
  }
  function pagination() {
    const total = Number(ui.data?.total) || 0,
      pages = Math.max(
        1,
        Math.ceil(total / (Number(ui.data?.page_size) || ui.pageSize)),
      );
    const first = total ? (ui.page - 1) * ui.pageSize + 1 : 0,
      last = Math.min(total, ui.page * ui.pageSize);
    return `<footer class="aw-pagination"><div class="aw-page-size"><span>${first.toLocaleString("fr-FR")}–${last.toLocaleString("fr-FR")} sur ${total.toLocaleString("fr-FR")}</span><label>Afficher <select onchange="PilozCRM.setActivityPageSize(this.value)">${[25, 50, 100, 200].map((size) => option(size, size, ui.pageSize)).join("")}</select></label></div><div><button ${ui.page <= 1 ? "disabled" : ""} onclick="PilozCRM.activityPage(${ui.page - 1})" aria-label="Page précédente">←</button><b>Page ${ui.page} sur ${pages}</b><button ${ui.page >= pages ? "disabled" : ""} onclick="PilozCRM.activityPage(${ui.page + 1})" aria-label="Page suivante">→</button></div></footer>`;
  }
  function empty() {
    return `<section class="aw-empty"><i>✓</i><h2>Aucune activité dans cette vue</h2><p>Modifiez les filtres ou planifiez votre prochaine action commerciale.</p>${ui.data?.permissions?.write ? button("Créer une activité", "PilozCRM.openActivityForm()", "primary") : ""}</section>`;
  }

  function calendarToolbar() {
    const label = new Intl.DateTimeFormat(
      "fr-FR",
      ui.calendarMode === "day"
        ? { dateStyle: "full" }
        : { month: "long", year: "numeric" },
    ).format(ui.calendarDate);
    return `<div class="aw-calendar-toolbar"><div><button onclick="PilozCRM.moveActivityCalendar(-1)" aria-label="Période précédente">←</button><button onclick="PilozCRM.todayActivityCalendar()">Aujourd’hui</button><button onclick="PilozCRM.moveActivityCalendar(1)" aria-label="Période suivante">→</button><b>${esc(label)}</b></div><div class="aw-calendar-modes">${["day", "week", "month"].map((id) => `<button class="${ui.calendarMode === id ? "active" : ""}" onclick="PilozCRM.setActivityCalendarMode('${id}')">${id === "day" ? "Jour" : id === "week" ? "Semaine" : "Mois"}</button>`).join("")}</div></div>`;
  }
  function calendarView() {
    const rows = ui.data?.rows || [],
      range = queryWindow(),
      start = new Date(range.start),
      days =
        ui.calendarMode === "day"
          ? 1
          : ui.calendarMode === "week"
            ? 7
            : new Date(start.getFullYear(), start.getMonth() + 1, 0).getDate();
    const dayRows = Array.from({ length: days }, (_, index) => {
      const day = new Date(start);
      day.setDate(start.getDate() + index);
      const items = rows.filter((row) => {
        const value = activityDate(row);
        return value && new Date(value).toDateString() === day.toDateString();
      });
      return `<section class="aw-calendar-day" data-date="${day.toISOString()}" ondragover="event.preventDefault()" ondrop="PilozCRM.dropActivityOnDate(event,this.dataset.date)"><header><span>${new Intl.DateTimeFormat("fr-FR", { weekday: "short" }).format(day)}</span><strong>${day.getDate()}</strong></header><div>${items.map((row) => `<button draggable="true" ondragstart="PilozCRM.dragActivityWorkspace(event,'${row.id}')" onclick="PilozCRM.openActivityDetail('${row.id}')" class="aw-calendar-event ${attr(row.status)}" style="--aw-type:${attr(row.type_color || "#14b8a6")}"><span>${formatTime(activityDate(row))}</span><b>${esc(row.subject)}</b><small>${esc(row.entity_name || memberName(row.assigned_user_id))}</small></button>`).join("")}</div><button class="aw-calendar-add" onclick="PilozCRM.openActivityForm('', '${day.toISOString()}')" aria-label="Créer le ${formatDate(day)}">+</button></section>`;
    }).join("");
    return `<section class="aw-calendar ${ui.calendarMode}">${dayRows}</section>`;
  }
  function timelineView() {
    const rows = ui.data?.rows || [];
    if (!rows.length) return empty();
    const now = new Date(),
      yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    const group = (value) => {
      const date = new Date(value);
      if (date.toDateString() === now.toDateString()) return "Aujourd’hui";
      if (date.toDateString() === yesterday.toDateString()) return "Hier";
      const days = (now - date) / 86400000;
      if (days < 7) return "Cette semaine";
      if (
        date.getMonth() === now.getMonth() &&
        date.getFullYear() === now.getFullYear()
      )
        return "Ce mois";
      return "Plus ancien";
    };
    const groups = {};
    rows.forEach((row) => (groups[group(activityDate(row))] ??= []).push(row));
    return `<section class="aw-timeline">${Object.entries(groups)
      .map(
        ([label, items]) =>
          `<div class="aw-timeline-group"><h2>${label}</h2>${items.map((row) => `<article><i style="--aw-type:${attr(row.type_color || "#14b8a6")}">${typeIcon(row.activity_type)}</i><div><header><button onclick="PilozCRM.openActivityDetail('${row.id}')">${esc(row.subject)}</button>${statusBadge(row)}</header><p>${esc(row.summary || row.description || "Aucun compte rendu.")}</p><footer>${formatDateTime(activityDate(row))} · ${esc(memberName(row.created_by))} · ${esc(linkedLabel(row))} · ${esc(sourceLabels[row.source] || row.source || "Manuelle")}</footer></div></article>`).join("")}</div>`,
      )
      .join("")}</section>${pagination()}`;
  }
  function render() {
    const main = document.getElementById("main");
    if (!main) return;
    main.innerHTML = `<main class="aw-shell">${header()}${metrics()}${toolbar()}${quickFilters()}${ui.view === "agenda" ? calendarView() : ui.view === "timeline" ? timelineView() : listView()}</main>`;
  }

  function entityOptions(rows, getLabel, selected) {
    return (
      option("", "Non lié", selected) +
      (rows || [])
        .filter((row) => !row.archived_at && row.active !== false)
        .map((row) => option(row.id, getLabel(row), selected))
        .join("")
    );
  }
  function relationPicker(
    kind,
    name,
    label,
    value = "",
    initialLabel = "",
    selectedType = kind,
  ) {
    const selectedLabel = initialLabel || (value ? "Relation enregistrée" : "");
    return `<label class="aw-relation-field"><span>${esc(label)}</span><div class="aw-relation-control"><input type="hidden" name="${attr(name)}" value="${attr(value)}"><input type="hidden" name="${attr(name)}_type" value="${attr(selectedType)}"><input type="search" autocomplete="off" value="${attr(selectedLabel)}" placeholder="Saisissez au moins 2 caractères…" aria-label="Rechercher ${attr(label.toLowerCase())}" oninput="PilozCRM.searchActivityRelation('${kind}','${name}',this.value)" onfocus="PilozCRM.searchActivityRelation('${kind}','${name}',this.value)"><button type="button" aria-label="Effacer" onclick="PilozCRM.clearActivityRelation('${name}')">×</button><div class="aw-relation-results" id="aw-relation-results-${attr(name)}" hidden></div></div></label>`;
  }
  function enterpriseFormBody(row = {}, detail = {}) {
    const types = ui.data?.types || [],
      start = row.starts_at || row.due_at || row.scheduled_at || "",
      links = detail.links || [],
      relationLink = (...types) =>
        links.find((link) => types.includes(link.entity_type)) || null,
      clientLink = relationLink("client", "prospect"),
      contactLink = relationLink("contact"),
      opportunityLink = relationLink("opportunity"),
      documentLink = relationLink("quote", "invoice", "credit_note"),
      supplierLink = relationLink("supplier"),
      reminder = (detail.reminders || []).find(
        (item) => item.status === "pending",
      ),
      checklist = (detail.checklist || []).map((item) => item.label).join("\n"),
      participants = (detail.participants || [])
        .map((item) => item.email || item.display_name)
        .filter(Boolean)
        .join("\n"),
      simpleOptions = (values, selected) =>
        values.map(([id, label]) => option(id, label, selected)).join("");
    return `<form id="aw-activity-form" class="aw-form" onsubmit="return false">
      <section class="aw-form-section"><h3>Action</h3><div class="aw-form-grid">
        <label><span>Type *</span><select name="activity_type_id" required>${types.map((type) => option(type.id, `${typeIcon(type.slug)} ${type.label}`, row.activity_type_id)).join("")}</select></label>
        <label><span>Responsable</span><select name="assigned_user_id">${ownerOptions(row.assigned_user_id || currentUser(), "Moi")}</select></label>
        <label class="wide"><span>Titre *</span><input name="subject" maxlength="180" value="${attr(row.subject || "")}" required placeholder="Ex. Relancer le devis avant vendredi"></label>
        <label class="wide"><span>Description</span><textarea name="description" rows="3" maxlength="10000" placeholder="Contexte, objectif et informations utiles">${esc(row.description || "")}</textarea></label>
      </div></section>
      <section class="aw-form-section"><h3>Planification</h3><div class="aw-form-grid">
        <label><span>Début *</span><input name="starts_at" type="datetime-local" value="${attr(localInput(start))}" required></label>
        <label><span>Fin</span><input name="ends_at" type="datetime-local" value="${attr(localInput(row.ends_at))}"></label>
        <label><span>Durée</span><div class="aw-input-suffix"><input name="duration_minutes" type="number" min="0" max="10080" value="${Number(row.duration_minutes) || 30}"><span>min</span></div></label>
        <label class="aw-check-label"><input name="all_day" type="checkbox" ${row.all_day ? "checked" : ""}><span>Journée entière</span></label>
        <label><span>Statut</span><select name="status">${Object.entries(
          statusLabels,
        )
          .map(([id, label]) => option(id, label, row.status || "scheduled"))
          .join("")}</select></label>
        <label><span>Priorité</span><select name="priority">${Object.entries(
          priorityLabels,
        )
          .map(([id, label]) => option(id, label, row.priority || "normal"))
          .join("")}</select></label>
      </div></section>
      <details open><summary>Relations métier</summary><div class="aw-form-grid">
        ${relationPicker("client", "client_id", "Client ou prospect", clientLink?.entity_id || row.client_id || "", row.entity_name || "", clientLink?.entity_type || "client")}
        ${relationPicker("contact", "contact_id", "Contact", contactLink?.entity_id || row.contact_id || "", row.contact_name || "")}
        ${relationPicker("opportunity", "opportunity_id", "Opportunité", opportunityLink?.entity_id || row.opportunity_id || "", row.opportunity_name || "")}
        ${relationPicker("document", "document_id", "Devis, facture ou avoir", documentLink?.entity_id || row.document_id || "", row.document_number || "", documentLink?.entity_type || "document")}
        ${relationPicker("supplier", "supplier_id", "Fournisseur", supplierLink?.entity_id || row.supplier_id || "", row.supplier_name || "")}
      </div></details>
      <details><summary>Informations complémentaires</summary><div class="aw-form-grid">
        <label><span>Confidentialité</span><select name="confidentiality">${Object.entries(
          confidentialityLabels,
        )
          .map(([id, label]) =>
            option(id, label, row.confidentiality || "standard"),
          )
          .join("")}</select></label>
        <label><span>Canal</span><select name="channel">${simpleOptions(
          [
            ["", "Non précisé"],
            ["telephone", "Téléphone"],
            ["email", "E-mail"],
            ["visio", "Visioconférence"],
            ["presentiel", "Présentiel"],
            ["interne", "Interne"],
          ],
          row.channel,
        )}</select></label>
        <label><span>Lieu</span><input name="location" value="${attr(row.location || "")}"></label>
        <label><span>Lien de visioconférence</span><input name="meeting_url" type="url" value="${attr(row.meeting_url || "")}"></label>
        <label class="wide"><span>Participants externes (un par ligne)</span><textarea name="participants" rows="3" placeholder="nom@entreprise.fr">${esc(participants)}</textarea></label>
        <label class="wide"><span>Checklist (une étape par ligne)</span><textarea name="checklist" rows="3" placeholder="Préparer la proposition\nEnvoyer le récapitulatif">${esc(checklist)}</textarea></label>
        <label><span>Rappel</span><input name="remind_at" type="datetime-local" value="${attr(localInput(reminder?.remind_at))}"></label>
        <label><span>Progression</span><div class="aw-input-suffix"><input name="completion_percent" type="number" min="0" max="100" value="${Number(row.completion_percent) || 0}"><span>%</span></div></label>
        <label class="wide"><span>Compte rendu</span><textarea name="summary" rows="3">${esc(row.summary || "")}</textarea></label>
        <label class="wide"><span>Prochaine étape</span><input name="next_step" value="${attr(row.next_step || "")}"></label>
      </div></details><p id="aw-form-error" class="aw-form-error" hidden></p>
    </form>`;
  }
  function formBody(row = {}, detail = {}) {
    const types = ui.data?.types || [],
      data = state().data || {},
      start = row.starts_at || row.due_at || row.scheduled_at || "",
      links = detail.links || [],
      relation = (type) =>
        links.find((link) => link.entity_type === type)?.entity_id ||
        row[
          `${type === "quote" || type === "invoice" ? "document" : type}_id`
        ] ||
        "",
      reminder = (detail.reminders || []).find(
        (item) => item.status === "pending",
      ),
      checklist = (detail.checklist || []).map((item) => item.label).join("\n"),
      participants = (detail.participants || [])
        .map((item) => item.email || item.display_name)
        .filter(Boolean)
        .join("\n");
    return `<form id="aw-activity-form" class="aw-form" onsubmit="return false"><div class="aw-form-grid"><label><span>Type *</span><select name="activity_type_id" required>${types.map((type) => option(type.id, `${typeIcon(type.slug)} ${type.label}`, row.activity_type_id)).join("")}</select></label><label class="wide"><span>Titre *</span><input name="subject" maxlength="180" value="${attr(row.subject || "")}" required placeholder="Ex. Appeler le client après le devis"></label><label class="wide"><span>Description</span><textarea name="description" rows="3" maxlength="10000" placeholder="Contexte et objectif de l’action">${esc(row.description || "")}</textarea></label><label><span>Début *</span><input name="starts_at" type="datetime-local" value="${attr(localInput(start))}" required></label><label><span>Fin</span><input name="ends_at" type="datetime-local" value="${attr(localInput(row.ends_at))}"></label><label><span>Durée (minutes)</span><input name="duration_minutes" type="number" min="0" max="10080" value="${Number(row.duration_minutes) || 30}"></label><label class="aw-check"><input name="all_day" type="checkbox" ${row.all_day ? "checked" : ""}><span>Journée entière</span></label><label><span>Statut</span><select name="status">${Object.entries(
      statusLabels,
    )
      .map(([id, label]) => option(id, label, row.status || "scheduled"))
      .join(
        "",
      )}</select></label><label><span>Priorité</span><select name="priority">${Object.entries(
      priorityLabels,
    )
      .map(([id, label]) => option(id, label, row.priority || "normal"))
      .join(
        "",
      )}</select></label><label><span>Responsable</span><select name="assigned_user_id">${ownerOptions(row.assigned_user_id || currentUser(), "Moi")}</select></label><label><span>Confidentialité</span><select name="confidentiality">${Object.entries(
      confidentialityLabels,
    )
      .map(([id, label]) =>
        option(id, label, row.confidentiality || "standard"),
      )
      .join(
        "",
      )}</select></label><label><span>Canal</span><select name="channel">${["", "telephone", "email", "visio", "presentiel", "interne"].map((id) => option(id, id ? { telephone: "Téléphone", email: "E-mail", visio: "Visioconférence", presentiel: "Présentiel", interne: "Interne" }[id] : "Non précisé", row.channel)).join("")}</select></label><label><span>Lieu</span><input name="location" value="${attr(row.location || "")}"></label><label class="wide"><span>Lien de visioconférence</span><input name="meeting_url" type="url" value="${attr(row.meeting_url || "")}"></label></div><details open><summary>Relations métier</summary><div class="aw-form-grid"><label><span>Client ou prospect</span><select name="client_id">${entityOptions(data.clients, (row) => row.trade_name || row.legal_name || [row.first_name, row.last_name].filter(Boolean).join(" ") || "Tiers", relation("client") || relation("prospect"))}</select></label><label><span>Contact</span><select name="contact_id">${entityOptions(data.clientContacts, (row) => [row.first_name, row.last_name].filter(Boolean).join(" ") || row.email || "Contact", relation("contact"))}</select></label><label><span>Opportunité</span><select name="opportunity_id">${entityOptions(data.opportunities, (row) => row.name || "Opportunité", relation("opportunity"))}</select></label><label><span>Document</span><select name="document_id">${entityOptions(data.documents, (row) => `${row.number || "Brouillon"} · ${row.document_type === "quote" ? "Devis" : row.document_type === "credit_note" ? "Avoir" : "Facture"}`, relation("quote") || relation("invoice") || relation("credit_note"))}</select></label><label><span>Fournisseur</span><select name="supplier_id">${entityOptions(data.suppliers, (row) => row.trade_name || row.legal_name || row.name || "Fournisseur", relation("supplier"))}</select></label></div></details><details><summary>Compte rendu et organisation</summary><div class="aw-form-grid"><label class="wide"><span>Participants externes (un par ligne)</span><textarea name="participants" rows="3" placeholder="nom@entreprise.fr">${esc(participants)}</textarea></label><label class="wide"><span>Checklist (une étape par ligne)</span><textarea name="checklist" rows="3" placeholder="Préparer la proposition\nEnvoyer le récapitulatif">${esc(checklist)}</textarea></label><label><span>Rappel</span><input name="remind_at" type="datetime-local" value="${attr(localInput(reminder?.remind_at))}"></label><label><span>Progression</span><input name="completion_percent" type="number" min="0" max="100" value="${Number(row.completion_percent) || 0}"></label><label class="wide"><span>Compte rendu</span><textarea name="summary" rows="3">${esc(row.summary || "")}</textarea></label><label class="wide"><span>Prochaine étape</span><input name="next_step" value="${attr(row.next_step || "")}"></label></div></details><p id="aw-form-error" class="aw-form-error" hidden></p></form>`;
  }
  async function openForm(id = "", preset = "") {
    try {
      let row = {},
        detail = {};
      if (id) {
        detail = await api().rpc("get_activity_detail", {
          target_activity_id: id,
        });
        row = detail.activity || {};
      } else if (preset) row.starts_at = preset;
      else {
        const start = new Date();
        start.setMinutes(Math.ceil(start.getMinutes() / 15) * 15, 0, 0);
        row.starts_at = start.toISOString();
      }
      modal(
        id ? "Modifier l’activité" : "Nouvelle activité",
        "Planifiez une action ou consignez un échange réalisé.",
        enterpriseFormBody(row, detail),
        `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button(id ? "Enregistrer" : "Créer l’activité", `PilozCRM.saveActivityWorkspace('${id}')`, "primary")}`,
        true,
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }
  function relationField(name) {
    const form = document.getElementById("aw-activity-form");
    return {
      form,
      hidden: form?.elements?.[name],
      type: form?.elements?.[`${name}_type`],
      input: form
        ?.querySelector(`[name="${CSS.escape(name)}"]`)
        ?.closest(".aw-relation-control")
        ?.querySelector('input[type="search"]'),
      results: document.getElementById(`aw-relation-results-${name}`),
    };
  }
  function clearRelation(name) {
    const field = relationField(name);
    if (field.hidden) field.hidden.value = "";
    if (field.input) {
      field.input.value = "";
      field.input.focus();
    }
    if (field.results) {
      field.results.hidden = true;
      field.results.innerHTML = "";
    }
  }
  function chooseRelation(name, encoded) {
    const item = JSON.parse(decodeURIComponent(encoded)),
      field = relationField(name);
    if (field.hidden) field.hidden.value = item.entity_id;
    if (field.type) field.type.value = item.entity_type;
    if (field.input) field.input.value = item.label;
    if (field.results) field.results.hidden = true;
    if (name === "client_id" && item.relation_meta?.relationship_type) {
      field.type.value = item.relation_meta.relationship_type;
    }
  }
  async function searchRelation(kind, name, value) {
    const field = relationField(name),
      query = String(value || "").trim();
    if (field.hidden && field.input?.value !== "Relation enregistrée") {
      field.hidden.value = "";
    }
    clearTimeout(ui.relationTimers.get(name));
    if (!field.results || query.length < 2) {
      if (field.results) field.results.hidden = true;
      return;
    }
    field.results.hidden = false;
    field.results.innerHTML = '<p class="aw-relation-state">Recherche…</p>';
    ui.relationTimers.set(
      name,
      setTimeout(async () => {
        try {
          const rows = await api().rpc("search_activity_relations", {
            target_kind: kind,
            target_search: query,
            target_limit: 20,
          });
          if (field.input?.value.trim() !== query) return;
          field.results.innerHTML = rows?.length
            ? rows
                .map((item) => {
                  const encoded = encodeURIComponent(JSON.stringify(item));
                  return `<button type="button" onclick="PilozCRM.chooseActivityRelation('${name}','${attr(encoded)}')"><b>${esc(item.label)}</b><small>${esc(item.subtitle || item.entity_type)}</small></button>`;
                })
                .join("")
            : '<p class="aw-relation-state">Aucun résultat. Vérifiez votre recherche.</p>';
        } catch (error) {
          if (missingRpc(error, "search_activity_relations")) {
            field.results.innerHTML =
              '<p class="aw-relation-state">La recherche distante sera disponible après la mise à jour de la base.</p>';
          } else {
            field.results.innerHTML = `<p class="aw-relation-state error">${esc(errorMessage(error))}</p>`;
          }
        }
      }, 250),
    );
  }
  function relationType(document) {
    return document?.document_type === "quote"
      ? "quote"
      : document?.document_type === "credit_note"
        ? "credit_note"
        : "invoice";
  }
  async function save(id = "") {
    const form = document.getElementById("aw-activity-form");
    if (!form?.reportValidity() || ui.busy) return;
    const values = Object.fromEntries(new FormData(form)),
      links = [];
    if (values.client_id) {
      links.push({
        entity_type: ["client", "prospect"].includes(values.client_id_type)
          ? values.client_id_type
          : "client",
        entity_id: values.client_id,
      });
    }
    if (values.contact_id)
      links.push({ entity_type: "contact", entity_id: values.contact_id });
    if (values.opportunity_id)
      links.push({
        entity_type: "opportunity",
        entity_id: values.opportunity_id,
      });
    if (values.document_id) {
      links.push({
        entity_type: ["quote", "invoice", "credit_note"].includes(
          values.document_id_type,
        )
          ? values.document_id_type
          : "invoice",
        entity_id: values.document_id,
      });
    }
    if (values.supplier_id)
      links.push({ entity_type: "supplier", entity_id: values.supplier_id });
    const participants = String(values.participants || "")
      .split(/\r?\n/)
      .map((value) => value.trim())
      .filter(Boolean)
      .map((value) =>
        value.includes("@")
          ? { participant_type: "external", email: value, display_name: value }
          : { participant_type: "external", display_name: value },
      );
    const checklist = String(values.checklist || "")
      .split(/\r?\n/)
      .map((value) => value.trim())
      .filter(Boolean)
      .map((label, position) => ({ label, position }));
    const reminders = values.remind_at
      ? [
          {
            channel: "in_app",
            remind_at: iso(values.remind_at),
            recipient_user_id: values.assigned_user_id || currentUser(),
          },
        ]
      : [];
    const payload = {
      activity_type_id: values.activity_type_id,
      subject: values.subject,
      description: values.description || null,
      status: values.status,
      priority: values.priority,
      starts_at: iso(values.starts_at),
      ends_at: iso(values.ends_at),
      due_at: iso(values.starts_at),
      duration_minutes: Number(values.duration_minutes) || 0,
      all_day: form.elements.all_day.checked,
      assigned_user_id: values.assigned_user_id || currentUser(),
      confidentiality: values.confidentiality,
      channel: values.channel || null,
      location: values.location || null,
      meeting_url: values.meeting_url || null,
      completion_percent: Number(values.completion_percent) || 0,
      summary: values.summary || null,
      next_step: values.next_step || null,
      source: "manual",
      links,
      participants,
      checklist,
      reminders,
    };
    ui.busy = true;
    try {
      const saved = await api().rpc("save_activity_workspace", {
        target_activity_id: id || null,
        target_payload: payload,
      });
      closeModal();
      await syncIfConfigured(saved.id);
      await load();
      notify(id ? "Activité mise à jour." : "Activité créée.", "success");
    } catch (error) {
      const node = document.getElementById("aw-form-error");
      if (node) {
        node.hidden = false;
        node.textContent = errorMessage(error);
      }
    } finally {
      ui.busy = false;
    }
  }
  async function syncIfConfigured(activityId) {
    for (const connection of ui.connections.filter(
      (row) =>
        row.settings?.export_activities === true &&
        row.settings?.sync_mode === "bidirectional",
    )) {
      try {
        await api().invoke("external-integrations", {
          action: "push_activity",
          connectionId: connection.id,
          activityId,
        });
      } catch (error) {
        console.warn("[PILOZ Activités] Synchronisation agenda échouée", {
          connectionId: connection.id,
          code: error?.code || "",
          status: error?.status || 0,
        });
        notify(
          "L’activité est enregistrée dans Piloz, mais sa synchronisation agenda a échoué.",
          "warning",
        );
      }
    }
  }

  async function openDetail(id) {
    try {
      const detail = await api().rpc("get_activity_detail", {
        target_activity_id: id,
      });
      ui.detail = detail;
      const row = detail.activity || {},
        events = detail.events || [],
        links = detail.links || [],
        attachments = detail.attachments || [],
        checklist = detail.checklist || [],
        sync = detail.sync || [];
      const body = `<article class="aw-detail"><section class="aw-detail-summary"><div>${activityType({ ...row, type_label: detail.type?.label, type_color: detail.type?.color })}<h3>${esc(row.subject)}</h3><p>${esc(row.description || "Aucune description.")}</p></div><dl><div><dt>Statut</dt><dd>${statusBadge(row)}</dd></div><div><dt>Priorité</dt><dd>${priorityBadge(row.priority)}</dd></div><div><dt>Date</dt><dd>${formatDateTime(activityDate(row))}</dd></div><div><dt>Responsable</dt><dd>${esc(memberName(row.assigned_user_id))}</dd></div><div><dt>Confidentialité</dt><dd>${esc(confidentialityLabels[row.confidentiality] || row.confidentiality)}</dd></div><div><dt>Origine</dt><dd>${esc(sourceLabels[row.source] || row.source)}</dd></div></dl></section>${row.summary ? `<section><h3>Compte rendu</h3><p>${esc(row.summary)}</p></section>` : ""}${row.next_step ? `<section><h3>Prochaine étape</h3><p>${esc(row.next_step)}</p></section>` : ""}<section><h3>Relations</h3><div class="aw-chips">${links.length ? links.map((link) => `<span>${esc(link.entity_type)} · ${esc(link.entity_id)}</span>`).join("") : "<span>Aucune relation</span>"}</div></section>${checklist.length ? `<section><h3>Checklist</h3><ul class="aw-checklist">${checklist.map((item) => `<li class="${item.completed_at ? "done" : ""}">${item.completed_at ? "✓" : "○"} ${esc(item.label)}</li>`).join("")}</ul></section>` : ""}<section><h3>Pièces jointes</h3><div class="aw-attachments">${attachments.length ? attachments.map((item) => `<button onclick="PilozCRM.downloadActivityAttachment('${item.storage_path}')">${esc(item.original_name)} <small>${Math.ceil(Number(item.size_bytes) / 1024)} Ko</small></button>`).join("") : "<p>Aucun fichier.</p>"}</div>${detail.can_write ? `<label class="aw-upload"><input type="file" onchange="PilozCRM.uploadActivityAttachment('${row.id}',this.files[0])">+ Ajouter une pièce jointe</label>` : ""}</section>${sync.length ? `<section><h3>Synchronisation</h3>${sync.map((item) => `<p>${esc(sourceLabels[item.provider] || item.provider)} · ${esc(item.sync_status)}${item.last_error_code ? ` · ${esc(item.last_error_code)}` : ""}</p>`).join("")}</section>` : ""}<section><h3>Historique</h3><ol class="aw-events">${events.map((event) => `<li><i></i><div><b>${esc(event.event_type.replaceAll("_", " "))}</b><span>${formatDateTime(event.occurred_at)} · ${esc(memberName(event.actor_user_id))}</span></div></li>`).join("") || "<li>Aucun événement.</li>"}</ol></section></article>`;
      const actions = detail.can_write
        ? `${!["completed", "cancelled"].includes(row.status) ? button("Terminer", `PilozCRM.openCompleteActivityWorkspace('${row.id}')`, "success") : ""}${button("Modifier", `PilozCRM.openActivityForm('${row.id}')`, "ghost")}${button("Reporter", `PilozCRM.openActivityReschedule('${row.id}')`, "ghost")}${button("Dupliquer", `PilozCRM.duplicateActivityWorkspace('${row.id}')`, "ghost")}${row.status !== "cancelled" ? button("Annuler", `PilozCRM.openActivityCancel('${row.id}')`, "danger") : ""}${button("Archiver", `PilozCRM.archiveActivityWorkspace('${row.id}')`, "danger")}`
        : "";
      modal(
        detail.type?.label || "Activité",
        `${formatDateTime(activityDate(row))} · ${memberName(row.assigned_user_id)}`,
        body,
        actions,
        true,
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }

  function completeForm(id) {
    const outcomes = (ui.data?.outcomes || []).filter(
      (row) =>
        !row.activity_type_id ||
        row.activity_type_id === ui.detail?.activity?.activity_type_id,
    );
    return `<form id="aw-complete-form" class="aw-form" onsubmit="return false"><div class="aw-form-grid"><label><span>Résultat</span><select name="outcome_id">${option("", "Non précisé", "")}${outcomes.map((row) => option(row.id, row.label, "")).join("")}</select></label><label><span>Durée réelle (minutes)</span><input name="actual_duration" type="number" min="0" max="10080"></label><label class="wide"><span>Compte rendu *</span><textarea name="summary" rows="4" required placeholder="Ce qui a été réalisé, décidé ou constaté"></textarea></label></div><details><summary>Planifier la prochaine action</summary><div class="aw-form-grid"><label><span>Type</span><select name="next_type_id">${option("", "Aucune activité suivante", "")}${(ui.data?.types || []).map((row) => option(row.id, row.label, "")).join("")}</select></label><label><span>Date</span><input name="next_starts_at" type="datetime-local"></label><label class="wide"><span>Titre</span><input name="next_subject" placeholder="Ex. Relancer après la proposition"></label></div></details><p id="aw-complete-error" class="aw-form-error" hidden></p></form>`;
  }
  function openComplete(id) {
    modal(
      "Terminer l’activité",
      "Ajoutez un compte rendu fiable et, si nécessaire, la prochaine action.",
      completeForm(id),
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Terminer", `PilozCRM.completeActivityWorkspace('${id}')`, "success")}`,
      true,
    );
  }
  async function complete(id) {
    const form = document.getElementById("aw-complete-form");
    if (!form?.reportValidity() || ui.busy) return;
    const values = Object.fromEntries(new FormData(form)),
      current = ui.detail?.activity || {},
      detail = ui.detail || {},
      next = values.next_type_id
        ? {
            activity_type_id: values.next_type_id,
            subject: values.next_subject || `Suivi · ${current.subject}`,
            status: "scheduled",
            priority: current.priority,
            starts_at: iso(values.next_starts_at),
            due_at: iso(values.next_starts_at),
            assigned_user_id: current.assigned_user_id || currentUser(),
            confidentiality: current.confidentiality || "standard",
            links: (detail.links || []).map((link) => ({
              entity_type: link.entity_type,
              entity_id: link.entity_id,
            })),
          }
        : null;
    if (next && !values.next_starts_at) {
      form.elements.next_starts_at.setCustomValidity(
        "Choisissez la date de la prochaine action.",
      );
      form.elements.next_starts_at.reportValidity();
      return;
    }
    ui.busy = true;
    try {
      await api().rpc("complete_activity_workspace", {
        target_activity_id: id,
        target_outcome_id: values.outcome_id || null,
        target_summary: values.summary,
        target_actual_duration: Number(values.actual_duration) || null,
        target_next_payload: next,
      });
      closeModal();
      await load();
      notify(
        next
          ? "Activité terminée et prochaine action planifiée."
          : "Activité terminée.",
        "success",
      );
    } catch (error) {
      const node = document.getElementById("aw-complete-error");
      if (node) {
        node.hidden = false;
        node.textContent = errorMessage(error);
      }
    } finally {
      ui.busy = false;
    }
  }

  function transitionDialog(id, mode) {
    if (mode === "cancel")
      modal(
        "Annuler l’activité",
        "Elle restera dans l’historique.",
        `<form id="aw-transition-form" class="aw-form"><label><span>Motif *</span><textarea name="reason" required rows="3"></textarea></label></form>`,
        `${button("Retour", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Confirmer l’annulation", `PilozCRM.runActivityTransition('${id}','cancel')`, "danger")}`,
      );
    else {
      const row =
        (ui.data?.rows || []).find((item) => item.id === id) ||
        ui.detail?.activity ||
        {};
      modal(
        "Reporter l’activité",
        "Choisissez une nouvelle date ; la modification sera journalisée.",
        `<form id="aw-transition-form" class="aw-form"><label><span>Nouvelle date *</span><input name="starts_at" type="datetime-local" value="${attr(localInput(activityDate(row)))}" required></label></form>`,
        `${button("Retour", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Reporter", `PilozCRM.runActivityTransition('${id}','reschedule')`, "primary")}`,
      );
    }
  }
  async function transition(id, action, value = null) {
    const form = document.getElementById("aw-transition-form");
    if (form && !form.reportValidity()) return;
    let payload = value || {};
    if (form) {
      const values = Object.fromEntries(new FormData(form));
      payload =
        action === "reschedule"
          ? { starts_at: iso(values.starts_at) }
          : { reason: values.reason };
    }
    try {
      await api().rpc("transition_activity_workspace", {
        target_activity_id: id,
        target_action: action,
        target_value: payload,
      });
      closeModal();
      await load();
      notify(
        action === "archive"
          ? "Activité archivée."
          : action === "cancel"
            ? "Activité annulée."
            : action === "reschedule"
              ? "Activité reportée."
              : "Activité mise à jour.",
        "success",
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }
  async function duplicate(id) {
    try {
      await api().rpc("duplicate_activity_workspace", {
        target_activity_id: id,
      });
      closeModal();
      await load();
      notify("Brouillon dupliqué.", "success");
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }
  async function uploadAttachment(id, file) {
    if (!file) return;
    if (file.size > 15728640) {
      notify("Le fichier dépasse 15 Mo.", "error");
      return;
    }
    const ext = (file.name.split(".").pop() || "bin")
        .replace(/[^a-z0-9]/gi, "")
        .toLowerCase(),
      path = `${state().companyId}/${id}/${Date.now()}-${crypto.randomUUID()}.${ext}`;
    try {
      await api().upload("activity-attachments", path, file, false);
      await api().rpc("register_activity_attachment", {
        target_activity_id: id,
        target_path: path,
        target_name: file.name,
        target_mime: file.type || "application/octet-stream",
        target_size: file.size,
        target_sha256: null,
      });
      await openDetail(id);
      notify("Pièce jointe ajoutée.", "success");
    } catch (error) {
      notify(
        errorMessage(error, "Le fichier n’a pas pu être ajouté."),
        "error",
      );
    }
  }
  async function downloadAttachment(path) {
    try {
      const signed = await api().signedUrl("activity-attachments", path, 300),
        url = signed?.signedURL || signed?.signedUrl || signed?.url;
      if (!url) throw new Error("Lien indisponible.");
      open(url, "_blank", "noopener");
    } catch (error) {
      notify(errorMessage(error, "Téléchargement impossible."), "error");
    }
  }

  function typeEditor(type = {}) {
    return `<form id="aw-type-form" class="aw-form"><input type="hidden" name="type_id" value="${attr(type.id || "")}"><div class="aw-form-grid"><label><span>Libellé *</span><input name="label" required maxlength="80" value="${attr(type.label || "")}"></label><label><span>Identifiant *</span><input name="slug" required pattern="[a-z][a-z0-9_]{1,48}" value="${attr(type.slug || "")}" ${type.id ? "readonly" : ""} placeholder="visite_technique"></label><label><span>Couleur</span><input name="color" type="color" value="${attr(type.color || "#14b8a6")}"></label><label><span>Durée par défaut</span><input name="default_duration_minutes" type="number" min="0" max="10080" value="${Number(type.default_duration_minutes) || 30}"></label></div></form>`;
  }
  function typeManager() {
    const types = ui.data?.all_types || ui.data?.types || [];
    return `<div class="aw-type-manager">${types.map((type) => `<article class="${type.active ? "" : "inactive"}"><i style="--aw-type:${attr(type.color)}">${typeIcon(type.slug)}</i><div><b>${esc(type.label)}</b><small>${esc(type.slug)} · ${type.default_duration_minutes} min</small></div><span>${type.active ? "Actif" : "Inactif"}</span><div class="aw-row-actions"><button type="button" onclick="PilozCRM.editActivityTypeWorkspace('${type.id}')" aria-label="Modifier ${attr(type.label)}">✎</button><button type="button" onclick="PilozCRM.toggleActivityTypeWorkspace('${type.id}',${type.active ? "false" : "true"})" aria-label="${type.active ? "Désactiver" : "Activer"} ${attr(type.label)}">${type.active ? "×" : "✓"}</button></div></article>`).join("")}</div>`;
  }
  function openTypes() {
    modal(
      "Types d’activités",
      "Les types sont configurés par entreprise et utilisés dans tous les écrans.",
      `${typeManager()}<h3>Ajouter un type</h3>${typeEditor()}`,
      `${button("Fermer", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Ajouter le type", "PilozCRM.saveActivityTypeWorkspace()", "primary")}`,
      true,
    );
  }
  function editType(id) {
    const type = (ui.data?.all_types || []).find((row) => row.id === id);
    if (!type) return;
    modal(
      "Modifier le type d’activité",
      "Les activités existantes conservent leur historique.",
      typeEditor(type),
      `${button("Annuler", "PilozCRM.openActivityTypes()", "ghost")}${button("Enregistrer", `PilozCRM.saveActivityTypeWorkspace('${id}')`, "primary")}`,
    );
  }
  async function saveType(id = "") {
    const form = document.getElementById("aw-type-form");
    if (!form?.reportValidity()) return;
    const values = Object.fromEntries(new FormData(form));
    try {
      await api().rpc("save_activity_type", {
        target_type_id: id || values.type_id || null,
        target_payload: {
          label: values.label,
          slug: values.slug,
          color: values.color,
          icon: "circle",
          category: "other",
          default_duration_minutes:
            Number(values.default_duration_minutes) || 30,
          active: true,
        },
      });
      closeModal();
      await load();
      notify(
        id ? "Type d’activité mis à jour." : "Type d’activité ajouté.",
        "success",
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }
  async function toggleType(id, active) {
    const type = (ui.data?.all_types || []).find((row) => row.id === id);
    if (!type) return;
    try {
      await api().rpc("save_activity_type", {
        target_type_id: id,
        target_payload: {
          label: type.label,
          slug: type.slug,
          color: type.color,
          icon: type.icon || "circle",
          category: type.category || "other",
          default_duration_minutes: Number(type.default_duration_minutes) || 30,
          active: Boolean(active),
        },
      });
      closeModal();
      await load();
      openTypes();
      notify(active ? "Type réactivé." : "Type désactivé.", "success");
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }

  async function bulk(action, value) {
    const ids = [...ui.selected];
    if (!ids.length || ui.busy) return;
    ui.busy = true;
    try {
      let result;
      try {
        result = await api().rpc("bulk_transition_activities_workspace", {
          target_activity_ids: ids,
          target_action: action,
          target_value: value,
        });
      } catch (error) {
        if (!missingRpc(error, "bulk_transition_activities_workspace"))
          throw error;
        let changed = 0;
        for (const id of ids) {
          await api().rpc("transition_activity_workspace", {
            target_activity_id: id,
            target_action: action,
            target_value: value,
          });
          changed += 1;
        }
        result = { changed, skipped: 0, failed: [] };
      }
      ui.selected.clear();
      await load();
      const changed = Number(result?.changed) || 0,
        skipped = Number(result?.skipped) || 0,
        failed = Array.isArray(result?.failed) ? result.failed.length : 0;
      notify(
        `${changed} activité(s) mise(s) à jour${skipped || failed ? ` · ${skipped + failed} ignorée(s)` : ""}.`,
        skipped || failed ? "warning" : "success",
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    } finally {
      ui.busy = false;
    }
  }
  function bulkReschedule() {
    modal(
      "Reporter les activités sélectionnées",
      "La même date sera appliquée aux activités autorisées.",
      `<form id="aw-bulk-form" class="aw-form"><label><span>Nouvelle date *</span><input name="starts_at" type="datetime-local" required></label></form>`,
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Reporter", `PilozCRM.runBulkReschedule()`, "primary")}`,
    );
  }
  async function runBulkReschedule() {
    const form = document.getElementById("aw-bulk-form");
    if (!form?.reportValidity()) return;
    const date = iso(new FormData(form).get("starts_at"));
    closeModal();
    await bulk("reschedule", { starts_at: date });
  }
  function bulkStatus() {
    modal(
      "Changer le statut",
      "Le statut choisi sera appliqué aux activités sélectionnées.",
      `<form id="aw-bulk-status-form" class="aw-form"><label><span>Nouveau statut *</span><select name="status" required>${Object.entries(
        statusLabels,
      )
        .map(([id, label]) => option(id, label, ""))
        .join("")}</select></label></form>`,
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Appliquer", "PilozCRM.runBulkActivityStatus()", "primary")}`,
    );
  }
  async function runBulkStatus() {
    const form = document.getElementById("aw-bulk-status-form");
    if (!form?.reportValidity()) return;
    const status = new FormData(form).get("status");
    closeModal();
    await bulk("status", { status });
  }
  function bulkAssign() {
    modal(
      "Attribuer les activités",
      "Le responsable choisi sera appliqué aux activités sélectionnées dans votre périmètre.",
      `<form id="aw-bulk-assign-form" class="aw-form"><label><span>Responsable *</span><select name="assigned_user_id" required>${ownerOptions("", "Choisir un responsable")}</select></label></form>`,
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Attribuer", "PilozCRM.runBulkActivityAssign()", "primary")}`,
    );
  }
  async function runBulkAssign() {
    const form = document.getElementById("aw-bulk-assign-form");
    if (!form?.reportValidity()) return;
    const assignedUserId = new FormData(form).get("assigned_user_id");
    closeModal();
    await bulk("assign", { assigned_user_id: assignedUserId, team_id: null });
  }
  async function dragDrop(event, date) {
    event.preventDefault();
    const id = event.dataTransfer.getData("text/activity-id");
    if (!id) return;
    const row = (ui.data?.rows || []).find((item) => item.id === id),
      target = new Date(date),
      source = new Date(activityDate(row));
    target.setHours(source.getHours(), source.getMinutes(), 0, 0);
    const duration = Number(row?.duration_minutes) || 30;
    try {
      await api().rpc("transition_activity_workspace", {
        target_activity_id: id,
        target_action: "reschedule",
        target_value: {
          starts_at: target.toISOString(),
          ends_at: new Date(target.getTime() + duration * 60000).toISOString(),
        },
      });
      await load();
    } catch (error) {
      notify(errorMessage(error), "error");
      await load();
    }
  }

  function openQuickCall() {
    openForm();
    setTimeout(() => {
      const form = document.getElementById("aw-activity-form");
      if (!form) return;
      const call = (ui.data?.types || []).find((type) => type.slug === "call");
      if (call) form.elements.activity_type_id.value = call.id;
      if (form.elements.subject && !form.elements.subject.value)
        form.elements.subject.value = "Appel commercial";
    }, 50);
  }
  function openSaveFilter() {
    modal(
      "Enregistrer ce filtre",
      "La vue et les critères seront retrouvés à votre prochaine connexion.",
      `<form id="aw-save-filter-form" class="aw-form"><label><span>Nom du filtre *</span><input name="name" required maxlength="100" placeholder="Ex. Relances urgentes de mon équipe"></label></form>`,
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Enregistrer", "PilozCRM.saveActivitySavedFilter()", "primary")}`,
    );
  }
  async function saveFilter() {
    const form = document.getElementById("aw-save-filter-form");
    if (!form?.reportValidity()) return;
    const name = new FormData(form).get("name"),
      filters = {
        search: ui.search || "",
        status: ui.status || "",
        type_id: ui.typeId || "",
        owner: ui.owner || "",
        team: ui.team || "",
        quick: ui.quick || "all",
        calendar_mode: ui.calendarMode || "week",
      };
    try {
      const saved = await api().rpc("save_activity_saved_filter", {
        target_filter_id: null,
        target_name: name,
        target_view_mode: ui.view,
        target_filters: filters,
      });
      ui.savedFilterId = saved?.id || "";
      closeModal();
      await load();
      notify("Filtre enregistré.", "success");
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }
  function applySavedFilter(id) {
    ui.savedFilterId = id;
    if (!id) {
      render();
      return;
    }
    const saved = (ui.data?.saved_filters || []).find((row) => row.id === id);
    if (!saved) return;
    const filters = saved.filters || {};
    ui.view = saved.view_mode || "list";
    ui.search = filters.search || "";
    ui.status = filters.status || "";
    ui.typeId = filters.type_id || "";
    ui.owner = filters.owner || "";
    ui.team = filters.team || "";
    ui.quick = filters.quick || "all";
    ui.calendarMode = filters.calendar_mode || "week";
    ui.page = 1;
    ui.selected.clear();
    load();
  }
  async function deleteSavedFilter() {
    const id = ui.savedFilterId;
    if (!id) return;
    try {
      await api().rpc("delete_activity_saved_filter", { target_filter_id: id });
      ui.savedFilterId = "";
      await load();
      notify("Filtre supprimé.", "success");
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }

  function openWorkspaceSettings() {
    const columnCards = Object.entries(columnLabels)
      .map(
        ([key, label]) =>
          `<label class="aw-setting-check"><input type="checkbox" name="visible_columns" value="${key}" ${visible(key) ? "checked" : ""}><span>${esc(label)}</span></label>`,
      )
      .join("");
    modal(
      "Personnaliser les activités",
      "Ces préférences sont enregistrées pour votre compte et retrouvées sur tous vos appareils.",
      `<form id="aw-settings-form" class="aw-form aw-settings-form" onsubmit="return false"><section><h3>Vue au démarrage</h3><div class="aw-form-grid"><label><span>Vue par défaut</span><select name="default_view">${[
        ["list", "Liste"],
        ["agenda", "Agenda"],
        ["timeline", "Chronologie"],
        ["mine", "Mes activités"],
        ["team", "Équipe"],
      ]
        .map(([id, label]) => option(id, label, ui.view))
        .join(
          "",
        )}</select></label><label><span>Activités par page</span><select name="page_size">${[25, 50, 100, 200].map((size) => option(size, size, ui.pageSize)).join("")}</select></label><label><span>Densité</span><select name="density">${option("comfortable", "Confortable", ui.density)}${option("compact", "Compacte", ui.density)}</select></label><label class="aw-check-label"><input type="checkbox" name="show_metrics" ${ui.showMetrics ? "checked" : ""}><span>Afficher les indicateurs</span></label></div></section><section><h3>Colonnes de la liste</h3><p>Gardez seulement les informations utiles à votre équipe.</p><div class="aw-setting-columns">${columnCards}</div></section></form>`,
      `${button("Annuler", "PilozCRM.closeActivitiesModal()", "ghost")}${button("Réinitialiser", "PilozCRM.resetActivityWorkspaceSettings()", "ghost")}${button("Enregistrer", "PilozCRM.saveActivityWorkspaceSettings()", "primary")}`,
      true,
    );
  }
  async function saveWorkspaceSettings(reset = false) {
    const form = document.getElementById("aw-settings-form"),
      values = form ? Object.fromEntries(new FormData(form)) : {},
      columns = reset
        ? defaultColumns
        : [
            ...(form?.querySelectorAll('[name="visible_columns"]:checked') ||
              []),
          ].map((node) => node.value),
      preferences = {
        default_view: reset ? "list" : values.default_view || ui.view,
        page_size: reset ? 50 : Number(values.page_size) || ui.pageSize,
        density: reset ? "comfortable" : values.density || ui.density,
        show_metrics: reset
          ? true
          : Boolean(form?.elements.show_metrics.checked),
        visible_columns: columns.length ? columns : defaultColumns,
        sort_key: reset ? "activity_at" : ui.sortKey,
        sort_direction: reset ? "asc" : ui.sortDirection,
      };
    try {
      await api().rpc("save_activity_workspace_preferences", {
        target_preferences: preferences,
      });
      applyPreferences(preferences);
      ui.view = preferences.default_view;
      ui.page = 1;
      closeModal();
      await load(true);
      notify(
        reset
          ? "Affichage réinitialisé."
          : "Affichage personnalisé enregistré.",
        "success",
      );
    } catch (error) {
      notify(errorMessage(error), "error");
    }
  }

  function sortActivities(key) {
    if (ui.sortKey === key)
      ui.sortDirection = ui.sortDirection === "asc" ? "desc" : "asc";
    else {
      ui.sortKey = key;
      ui.sortDirection = "asc";
    }
    ui.page = 1;
    load();
  }

  function setView(value) {
    ui.view = value;
    ui.page = 1;
    ui.selected.clear();
    load();
  }
  function setQuick(value) {
    ui.quick = value;
    ui.page = 1;
    load();
  }
  function search(value) {
    ui.search = value;
    clearTimeout(ui.searchTimer);
    ui.searchTimer = setTimeout(() => {
      ui.page = 1;
      load();
    }, 300);
  }
  function changeCalendar(step) {
    const date = new Date(ui.calendarDate);
    if (ui.calendarMode === "month") date.setMonth(date.getMonth() + step);
    else
      date.setDate(
        date.getDate() + step * (ui.calendarMode === "week" ? 7 : 1),
      );
    ui.calendarDate = date;
    load();
  }
  function select(id, checked) {
    checked ? ui.selected.add(id) : ui.selected.delete(id);
    render();
  }
  function selectAll(checked) {
    ui.selected.clear();
    if (checked)
      (ui.data?.rows || []).forEach((row) => ui.selected.add(row.id));
    render();
  }
  async function openForEntity(entityType, entityId, preset = {}) {
    if (!ui.data) await load();
    openForm("", preset.starts_at || preset.due_at || "");
    setTimeout(() => {
      const form = document.getElementById("aw-activity-form");
      if (!form) return;
      const map = {
        client: "client_id",
        prospect: "client_id",
        contact: "contact_id",
        opportunity: "opportunity_id",
        quote: "document_id",
        invoice: "document_id",
        credit_note: "document_id",
        supplier: "supplier_id",
      };
      const field = form.elements[map[entityType]];
      if (field) {
        field.value = entityId;
        const typeField = form.elements[`${map[entityType]}_type`];
        if (typeField) typeField.value = entityType;
      }
      if (preset.client_id && form.elements.client_id) {
        form.elements.client_id.value = preset.client_id;
        form.elements.client_id_type.value = "client";
      }
      if (preset.activity_type && form.elements.activity_type_id) {
        const wanted = (ui.data?.types || []).find(
          (type) => type.slug === preset.activity_type,
        );
        if (wanted) form.elements.activity_type_id.value = wanted.id;
      }
      if (preset.subject) form.elements.subject.value = preset.subject;
    }, 60);
  }
  function openQuickCompatibility(id = "", links = {}) {
    if (id) return openForm(id);
    if (links.opportunity_id)
      return openForEntity("opportunity", links.opportunity_id, links);
    if (links.document_id) {
      const document = (state().data?.documents || []).find(
        (item) => item.id === links.document_id,
      );
      return openForEntity(
        document?.document_type || "invoice",
        links.document_id,
        links,
      );
    }
    if (links.contact_id)
      return openForEntity("contact", links.contact_id, links);
    if (links.client_id) return openForEntity("client", links.client_id, links);
    return openForm("", links.starts_at || links.due_at || "");
  }
  document.addEventListener("keydown", (event) => {
    if (
      event.key === "Escape" &&
      document.getElementById("activity-workspace-modal")
    )
      closeModal();
  });
  document.addEventListener("pointerdown", (event) => {
    if (event.target.closest(".aw-relation-control")) return;
    document.querySelectorAll(".aw-relation-results").forEach((results) => {
      results.hidden = true;
    });
  });
  Object.assign(crm, {
    activitiesWorkspace: ui,
    loadActivitiesWorkspace: load,
    closeActivitiesModal: closeModal,
    setActivityWorkspaceView: setView,
    setActivityQuick: setQuick,
    searchActivities: search,
    toggleActivityAdvancedFilters() {
      ui.advancedFilters = !ui.advancedFilters;
      render();
    },
    openActivityWorkspaceSettings: openWorkspaceSettings,
    saveActivityWorkspaceSettings: () => saveWorkspaceSettings(false),
    resetActivityWorkspaceSettings: () => saveWorkspaceSettings(true),
    sortActivities,
    setActivityPageSize(value) {
      ui.pageSize = Number(value) || 50;
      ui.page = 1;
      load();
    },
    searchActivityRelation: searchRelation,
    chooseActivityRelation: chooseRelation,
    clearActivityRelation: clearRelation,
    setActivityType(value) {
      ui.typeId = value;
      ui.page = 1;
      load();
    },
    setActivityStatus(value) {
      ui.status = value;
      ui.page = 1;
      load();
    },
    setActivityOwner(value) {
      ui.owner = value;
      ui.page = 1;
      load();
    },
    activityPage(value) {
      ui.page = Math.max(1, value);
      load();
    },
    selectActivity: select,
    selectAllActivities: selectAll,
    openActivityForm: openForm,
    openQuickActivity: openQuickCompatibility,
    openQuickCallWorkspace: openQuickCall,
    saveActivityWorkspace: save,
    openActivityDetail: openDetail,
    openCompleteActivityWorkspace: openComplete,
    completeActivityWorkspace: complete,
    openActivityReschedule: (id) => transitionDialog(id, "reschedule"),
    openActivityCancel: (id) => transitionDialog(id, "cancel"),
    runActivityTransition: transition,
    archiveActivityWorkspace: (id) => transition(id, "archive", {}),
    duplicateActivityWorkspace: duplicate,
    uploadActivityAttachment: uploadAttachment,
    downloadActivityAttachment,
    openActivityTypes: openTypes,
    editActivityTypeWorkspace: editType,
    toggleActivityTypeWorkspace: toggleType,
    saveActivityTypeWorkspace: saveType,
    bulkActivityAction: bulk,
    openBulkReschedule: bulkReschedule,
    runBulkReschedule,
    openBulkActivityStatus: bulkStatus,
    runBulkActivityStatus,
    openBulkActivityAssign: bulkAssign,
    runBulkActivityAssign,
    openSaveActivityFilter: openSaveFilter,
    saveActivitySavedFilter: saveFilter,
    applyActivitySavedFilter: applySavedFilter,
    deleteActivitySavedFilter: deleteSavedFilter,
    dragActivityWorkspace(event, id) {
      event.dataTransfer.setData("text/activity-id", id);
      event.dataTransfer.effectAllowed = "move";
    },
    dropActivityOnDate: dragDrop,
    setActivityCalendarMode(value) {
      ui.calendarMode = value;
      load();
    },
    moveActivityCalendar: changeCalendar,
    todayActivityCalendar() {
      ui.calendarDate = new Date();
      load();
    },
    openActivityForEntity: openForEntity,
  });
  crm.reloadActivities = load;
  const modern = global.PilozModern;
  if (modern && !modern.__activitiesWorkspaceRouteInstalled) {
    const previousRenderRoute = modern.renderRoute?.bind(modern);
    modern.renderRoute = function activitiesWorkspaceRoute(
      routeName,
      runtimeState,
    ) {
      const current = route();
      if (
        current === "crm/activities" ||
        current === "activities" ||
        routeName === "activities"
      ) {
        load();
        return true;
      }
      return previousRenderRoute?.(routeName, runtimeState) || false;
    };
    modern.__activitiesWorkspaceRouteInstalled = true;
  }
})(window);
