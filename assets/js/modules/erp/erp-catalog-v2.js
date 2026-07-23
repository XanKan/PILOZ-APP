(function (global) {
  "use strict";
  const api = () => global.PilozERP,
    app = () => global.PilozApp;
  const ui = {
    query: "",
    quick: "all",
    filters: {
      type: "",
      status: "",
      category: "",
      supplier: "",
      stock: "",
      vat: "",
      unit: "",
      brand: "",
      price: "",
    },
    sort: "name",
    direction: "asc",
    page: 1,
    pageSize: 25,
    view: "list",
    selected: new Set(),
    columns: null,
    tab: "summary",
    editing: false,
    busy: false,
    importRows: [],
    importStep: 1,
    importFileName: "catalogue.csv",
    importMode: "skip",
  };
  const defaultColumns = [
    "designation",
    "type",
    "reference",
    "category",
    "purchase",
    "sale",
    "margin",
    "vat",
    "stock",
    "supplier",
    "status",
    "updated",
    "actions",
  ];
  const columnLabels = {
    designation: "Désignation",
    type: "Type",
    reference: "Référence",
    category: "Catégorie",
    purchase: "Achat HT",
    sale: "Vente HT",
    margin: "Marge",
    vat: "TVA",
    stock: "Stock / service",
    supplier: "Fournisseur principal",
    status: "Statut",
    updated: "Dernière modification",
    actions: "Actions",
  };
  const typeLabels = {
    product: "Article",
    service: "Service",
    subscription: "Abonnement",
    package: "Pack / kit",
    fee: "Frais",
    discount: "Remise",
    comment: "Commentaire",
  };
  const statusLabels = {
    active: "Actif",
    inactive: "Inactif",
    draft: "Brouillon",
    discontinued: "Arrêté",
    archived: "Archivé",
  };
  const defaultUnits = [
    "unité",
    "heure",
    "jour",
    "forfait",
    "mètre",
    "m²",
    "m³",
    "kilogramme",
    "litre",
    "lot",
    "mois",
  ];
  function catalogUnits() {
    const configured = state().data.catalogSettings?.[0]?.units,
      values = Array.isArray(configured) && configured.length ? configured : defaultUnits;
    return [...new Set(values.map((value) => String(value || "").trim()).filter(Boolean))];
  }
  function unitField(label, name, value = "unité") {
    return `<label class="modern-field"><span>${esc(label)}</span><input name="${name}" list="catalog-unit-options" value="${esc(value || "unité")}" autocomplete="off"><small>Choisissez une unité ou saisissez-en une librement.</small></label>`;
  }
  function unitOptions() {
    return `<datalist id="catalog-unit-options">${catalogUnits().map((unit) => `<option value="${esc(unit)}"></option>`).join("")}</datalist>`;
  }
  const esc = (value) =>
    global.esc
      ? global.esc(value)
      : String(value ?? "").replace(
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
  const money = (value) =>
    new Intl.NumberFormat("fr-FR", {
      style: "currency",
      currency: "EUR",
    }).format(Number(value) || 0);
  const number = (value) =>
    new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 2 }).format(
      Number(value) || 0,
    );
  const date = (value) =>
    value
      ? new Intl.DateTimeFormat("fr-FR", { dateStyle: "medium" }).format(
          new Date(value),
        )
      : "—";
  const idSafe = (value) => String(value || "").replace(/[^a-zA-Z0-9_-]/g, "");
  const state = () => app().getState();
  function notify(message, kind = "info") {
    global.PilozCommercialV2?.notify?.(message, kind) ||
      global.toast?.(message);
  }
  function localKey() {
    return `piloz.catalog.ui.${state().companyId || "none"}.${global.PilozRuntime?.session?.user_id || "none"}`;
  }
  function restore() {
    try {
      const saved = JSON.parse(localStorage.getItem(localKey()) || "{}");
      Object.assign(ui, {
        query: saved.query || "",
        quick: saved.quick || "all",
        filters: { ...ui.filters, ...(saved.filters || {}) },
        sort: saved.sort || "name",
        direction: saved.direction || "asc",
        pageSize: Number(saved.pageSize) || 25,
        view: saved.view === "cards" ? "cards" : "list",
        columns: Array.isArray(saved.columns) ? saved.columns : null,
      });
    } catch {}
    if (!ui.columns) ui.columns = [...defaultColumns];
  }
  function persist() {
    localStorage.setItem(
      localKey(),
      JSON.stringify({
        query: ui.query,
        quick: ui.quick,
        filters: ui.filters,
        sort: ui.sort,
        direction: ui.direction,
        pageSize: ui.pageSize,
        view: ui.view,
        columns: ui.columns,
      }),
    );
  }
  function catalog() {
    return state().data.catalog || [];
  }
  function category(item) {
    return (state().data.categories || []).find(
      (row) => row.id === item.category_id,
    );
  }
  function supplier(item) {
    return (
      (state().data.suppliers || []).find(
        (row) => row.id === item.primary_supplier_id,
      ) ||
      (state().data.suppliers || []).find(
        (row) =>
          row.id ===
          (state().data.supplierItems || []).find(
            (link) => link.catalog_item_id === item.id && link.is_primary,
          )?.supplier_id,
      )
    );
  }
  function levels(itemId) {
    const rows = (state().data.levels || []).filter(
      (row) => row.item_id === itemId,
    );
    return rows.reduce(
      (sum, row) => ({
        physical: sum.physical + Number(row.physical_quantity || 0),
        reserved: sum.reserved + Number(row.reserved_quantity || 0),
        available:
          sum.available +
          Number(
            row.available_quantity ??
              Number(row.physical_quantity || 0) -
                Number(row.reserved_quantity || 0),
          ),
        expected: sum.expected + Number(row.expected_quantity || 0),
        transit: sum.transit + Number(row.in_transit_quantity || 0),
      }),
      { physical: 0, reserved: 0, available: 0, expected: 0, transit: 0 },
    );
  }
  function cost(item) {
    return Number(item.cost_price ?? item.purchase_price) || 0;
  }
  function margin(item) {
    return Number(item.sale_price || 0) - cost(item);
  }
  function marginRate(item) {
    const c = cost(item);
    return c ? (margin(item) / c) * 100 : null;
  }
  function can(permission) {
    const member = (state().data.members || []).find(
      (row) => row.user_id === global.PilozRuntime?.session?.user_id,
    );
    return (
      !!member &&
      (member.role === "owner" ||
        member.role === "admin" ||
        member.permissions?.[permission] === true)
    );
  }
  function statusOf(item) {
    return item.status || (item.active === false ? "inactive" : "active");
  }
  function searchText(item) {
    const links = (state().data.supplierItems || []).filter(
        (x) => x.catalog_item_id === item.id,
      ),
      tags = (state().data.itemTagAssignments || [])
        .filter((x) => x.item_id === item.id)
        .map(
          (x) =>
            (state().data.itemTags || []).find((t) => t.id === x.tag_id)?.name,
        ),
      supplierNames = links.map(
        (link) =>
          (state().data.suppliers || []).find((x) => x.id === link.supplier_id)
            ?.legal_name,
      );
    return [
      item.name,
      item.reference,
      item.barcode,
      item.short_description,
      item.sales_description,
      item.detailed_description,
      item.category,
      item.subcategory,
      item.brand,
      item.manufacturer_reference,
      ...(item.aliases || []),
      ...links.map((x) => x.supplier_reference),
      ...supplierNames,
      ...tags,
    ]
      .filter(Boolean)
      .join(" ")
      .toLocaleLowerCase("fr");
  }
  function filtered() {
    let rows = catalog().filter((item) => {
      const query = ui.query.trim().toLocaleLowerCase("fr"),
        st = statusOf(item),
        lv = levels(item.id),
        f = ui.filters;
      if (query && !searchText(item).includes(query)) return false;
      if (ui.quick === "products" && item.item_type !== "product") return false;
      if (ui.quick === "services" && item.item_type !== "service") return false;
      if (
        ui.quick === "low" &&
        (!item.stock_managed ||
          lv.available > Number(item.reorder_point ?? item.minimum_stock ?? 0))
      )
        return false;
      if (ui.quick === "out" && (!item.stock_managed || lv.available > 0))
        return false;
      if (ui.quick === "no-price" && Number(item.sale_price) > 0) return false;
      if (ui.quick === "inactive" && st === "active") return false;
      if (f.type && item.item_type !== f.type) return false;
      if (f.status && st !== f.status) return false;
      if (f.category && item.category_id !== f.category) return false;
      if (
        f.supplier &&
        !(state().data.supplierItems || []).some(
          (link) =>
            link.catalog_item_id === item.id &&
            link.supplier_id === f.supplier &&
            link.active !== false,
        )
      )
        return false;
      if (f.vat && Number(item.tax_rate) !== Number(f.vat)) return false;
      if (f.unit && item.unit !== f.unit) return false;
      if (f.brand && item.brand !== f.brand) return false;
      if (
        f.stock === "low" &&
        (!item.stock_managed ||
          lv.available > Number(item.reorder_point ?? item.minimum_stock ?? 0))
      )
        return false;
      if (f.stock === "out" && (!item.stock_managed || lv.available > 0))
        return false;
      if (f.stock === "managed" && !item.stock_managed) return false;
      if (f.price === "no-purchase" && cost(item) > 0) return false;
      if (f.price === "no-sale" && Number(item.sale_price) > 0) return false;
      if (f.price === "no-supplier" && supplier(item)) return false;
      if (f.price === "no-category" && item.category_id) return false;
      return true;
    });
    rows.sort((a, b) => {
      let av, bv;
      switch (ui.sort) {
        case "reference":
          av = a.reference;
          bv = b.reference;
          break;
        case "sale":
          av = Number(a.sale_price);
          bv = Number(b.sale_price);
          break;
        case "purchase":
          av = cost(a);
          bv = cost(b);
          break;
        case "stock":
          av = levels(a.id).available;
          bv = levels(b.id).available;
          break;
        case "updated":
          av = a.updated_at;
          bv = b.updated_at;
          break;
        default:
          av = a.name;
          bv = b.name;
      }
      const result =
        typeof av === "number"
          ? av - bv
          : String(av || "").localeCompare(String(bv || ""), "fr", {
              numeric: true,
              sensitivity: "base",
            });
      return ui.direction === "desc" ? -result : result;
    });
    return rows;
  }
  function stats() {
    const all = catalog(),
      active = all.filter((x) => statusOf(x) === "active"),
      products = active.filter((x) => x.item_type === "product"),
      services = active.filter((x) => x.item_type === "service"),
      out = products.filter(
        (x) => x.stock_managed && levels(x.id).available <= 0,
      ),
      low = products.filter(
        (x) =>
          x.stock_managed &&
          levels(x.id).available > 0 &&
          levels(x.id).available <=
            Number(x.reorder_point ?? x.minimum_stock ?? 0),
      ),
      noPrice = all.filter((x) => Number(x.sale_price) <= 0),
      noSupplier = products.filter((x) => !supplier(x)),
      margins = active.filter((x) => marginRate(x) !== null).map(marginRate),
      value = products.reduce(
        (total, x) => total + levels(x.id).physical * cost(x),
        0,
      );
    return {
      products: products.length,
      services: services.length,
      out: out.length,
      low: low.length,
      noPrice: noPrice.length,
      noSupplier: noSupplier.length,
      value,
      averageMargin: margins.length
        ? margins.reduce((a, b) => a + b, 0) / margins.length
        : 0,
    };
  }
  function routePath() {
    return (location.hash || "#sales/catalog").slice(1).split("?")[0];
  }
  function top() {
    return `<header class="catalog-top"><div><span>Ventes</span><h1>Articles & services</h1><p>Catalogue, prix, fournisseurs et stock au même endroit.</p></div><div class="catalog-top-actions"><button class="btn btn-o" onclick="PilozCatalog.openTaxonomy()">Paramètres du catalogue</button><button class="btn btn-o" onclick="PilozCatalog.openImport()">Importer</button><button class="btn btn-o" onclick="PilozCatalog.exportCsv('filtered')">Exporter</button><button class="btn btn-p" onclick="PilozApp.go('sales/catalog/new')">Nouvel élément</button></div></header>`;
  }
  function quickCounts() {
    const s = stats(),
      all = catalog();
    return {
      all: all.length,
      products: s.products,
      services: s.services,
      low: s.low,
      out: s.out,
      "no-price": s.noPrice,
      inactive: all.filter((x) => statusOf(x) !== "active").length,
    };
  }
  function metric(label, value, quick, format = "number") {
    return `<button class="catalog-metric" onclick="PilozCatalog.setQuick('${quick}')"><span>${esc(label)}</span><b>${format === "money" ? money(value) : format === "percent" ? number(value) + " %" : number(value)}</b></button>`;
  }
  function filterOptions(rows, key, label) {
    return [...new Set(rows.map((x) => x[key]).filter(Boolean))]
      .sort((a, b) => String(a).localeCompare(String(b), "fr"))
      .map(
        (value) =>
          `<option value="${esc(value)}" ${ui.filters[key] === value ? "selected" : ""}>${esc(value)}</option>`,
      )
      .join("");
  }
  function toolbar() {
    const counts = quickCounts(),
      categories = state().data.categories || [],
      suppliers = state().data.suppliers || [],
      rates = state().data.vatRates || [];
    return `<section class="catalog-controls"><div class="catalog-quick-tabs">${[
      ["all", "Tous"],
      ["products", "Articles"],
      ["services", "Services"],
      ["low", "Stock faible"],
      ["out", "En rupture"],
      ["no-price", "Sans prix"],
      ["inactive", "Inactifs"],
    ]
      .map(
        ([key, label]) =>
          `<button class="${ui.quick === key ? "active" : ""}" onclick="PilozCatalog.setQuick('${key}')">${label}<span>${counts[key] || 0}</span></button>`,
      )
      .join(
        "",
      )}</div><div class="catalog-toolbar"><label class="catalog-search"><span>⌕</span><input id="catalog-search" type="search" value="${esc(ui.query)}" placeholder="Désignation, référence, code-barres, fournisseur…" oninput="PilozCatalog.setSearch(this.value)"></label><button class="btn btn-o" onclick="PilozCatalog.toggleFilters()">Filtres <span id="catalog-filter-count">${Object.values(ui.filters).filter(Boolean).length || ""}</span></button><button class="btn btn-o" onclick="PilozCatalog.openSavedViews()">Vues</button><div class="catalog-view-switch"><button class="${ui.view === "list" ? "active" : ""}" title="Liste" onclick="PilozCatalog.setView('list')">☷</button><button class="${ui.view === "cards" ? "active" : ""}" title="Cartes" onclick="PilozCatalog.setView('cards')">▦</button></div><button class="btn btn-o" onclick="PilozCatalog.openColumns()">Colonnes</button></div><div id="catalog-filters" class="catalog-filters" hidden><label>Type<select onchange="PilozCatalog.setFilter('type',this.value)"><option value="">Tous</option>${Object.entries(
      typeLabels,
    )
      .map(
        ([k, v]) =>
          `<option value="${k}" ${ui.filters.type === k ? "selected" : ""}>${v}</option>`,
      )
      .join(
        "",
      )}</select></label><label>Statut<select onchange="PilozCatalog.setFilter('status',this.value)"><option value="">Tous</option>${Object.entries(
      statusLabels,
    )
      .map(
        ([k, v]) =>
          `<option value="${k}" ${ui.filters.status === k ? "selected" : ""}>${v}</option>`,
      )
      .join(
        "",
      )}</select></label><label>Catégorie<select onchange="PilozCatalog.setFilter('category',this.value)"><option value="">Toutes</option>${categories.map((x) => `<option value="${x.id}" ${ui.filters.category === x.id ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select></label><label>Fournisseur<select onchange="PilozCatalog.setFilter('supplier',this.value)"><option value="">Tous</option>${suppliers.map((x) => `<option value="${x.id}" ${ui.filters.supplier === x.id ? "selected" : ""}>${esc(x.legal_name)}</option>`).join("")}</select></label><label>TVA<select onchange="PilozCatalog.setFilter('vat',this.value)"><option value="">Toutes</option>${rates.map((x) => `<option value="${Number(x.rate)}" ${Number(ui.filters.vat) === Number(x.rate) ? "selected" : ""}>${esc(x.label)}</option>`).join("")}</select></label><label>Unité<select onchange="PilozCatalog.setFilter('unit',this.value)"><option value="">Toutes</option>${filterOptions(catalog(), "unit", "Unité")}</select></label><label>Marque<select onchange="PilozCatalog.setFilter('brand',this.value)"><option value="">Toutes</option>${filterOptions(catalog(), "brand", "Marque")}</select></label><label>Stock<select onchange="PilozCatalog.setFilter('stock',this.value)"><option value="">Tous</option><option value="managed">Géré</option><option value="low">Sous seuil</option><option value="out">En rupture</option></select></label><label>Complétude<select onchange="PilozCatalog.setFilter('price',this.value)"><option value="">Toutes</option><option value="no-purchase">Sans prix d’achat</option><option value="no-sale">Sans prix de vente</option><option value="no-supplier">Sans fournisseur</option><option value="no-category">Sans catégorie</option></select></label><button class="catalog-clear" onclick="PilozCatalog.clearFilters()">Réinitialiser</button></div></section>`;
  }
  function cell(key, item) {
    const lv = levels(item.id),
      cat = category(item),
      sup = supplier(item),
      rate = marginRate(item);
    switch (key) {
      case "designation":
        return `<td class="catalog-designation"><button onclick="PilozApp.go('sales/items/${item.id}')"><b>${esc(item.name)}</b><small>${esc(item.short_description || item.brand || "")}</small></button></td>`;
      case "type":
        return `<td><span class="catalog-type">${esc(typeLabels[item.item_type] || item.item_type)}</span></td>`;
      case "reference":
        return `<td class="catalog-mono">${esc(item.reference || "—")}</td>`;
      case "category":
        return `<td>${cat ? `<span class="catalog-category" style="--tag:${esc(cat.color || "#E7F5F3")}">${esc(cat.name)}</span>` : "—"}</td>`;
      case "purchase":
        return can("view_purchase_prices")
          ? `<td>${money(cost(item))}</td>`
          : "";
      case "sale":
        return `<td><b>${money(item.sale_price)}</b></td>`;
      case "margin":
        return can("view_margins")
          ? `<td>${money(margin(item))}<small>${rate === null ? "—" : number(rate) + " %"}</small></td>`
          : "";
      case "vat":
        return `<td>${number(item.tax_rate)} %</td>`;
      case "stock":
        return item.item_type === "service"
          ? `<td>${esc(item.billing_unit || item.unit || "Prestation")}<small>${item.estimated_duration_minutes ? number(item.estimated_duration_minutes) + " min" : "Tarif " + money(item.sale_price)}</small></td>`
          : `<td><b class="${lv.available <= 0 && item.stock_managed ? "catalog-stock-alert" : ""}">${item.stock_managed ? number(lv.available) : "Non géré"}</b>${item.stock_managed ? `<small>${number(lv.reserved)} réservé · ${number(lv.expected)} à recevoir</small>` : ""}</td>`;
      case "supplier":
        return `<td>${esc(sup?.legal_name || "—")}</td>`;
      case "status":
        return `<td><span class="catalog-status ${statusOf(item)}">${esc(statusLabels[statusOf(item)] || statusOf(item))}</span></td>`;
      case "updated":
        return `<td>${date(item.updated_at)}</td>`;
      case "actions":
        return `<td class="catalog-actions"><button title="Modifier" onclick="event.stopPropagation();PilozCatalog.openEditor('${item.id}')">✎</button><button title="Dupliquer" onclick="event.stopPropagation();PilozCatalog.duplicate('${item.id}')">⧉</button></td>`;
      default:
        return "";
    }
  }
  function listRows(rows) {
    if (!rows.length)
      return `<div class="catalog-empty"><b>Aucun élément</b><p>Modifiez les filtres ou créez le premier élément du catalogue.</p><button class="btn btn-p" onclick="PilozApp.go('sales/catalog/new')">Créer un élément</button></div>`;
    if (ui.view === "cards")
      return `<div class="catalog-card-grid">${rows
        .map((item) => {
          const lv = levels(item.id);
          return `<article class="catalog-item-card" onclick="PilozApp.go('sales/items/${item.id}')"><header><span class="catalog-type">${esc(typeLabels[item.item_type])}</span><span class="catalog-status ${statusOf(item)}">${esc(statusLabels[statusOf(item)])}</span></header><h3>${esc(item.name)}</h3><p>${esc(item.reference || "Sans référence")} · ${esc(category(item)?.name || "Sans catégorie")}</p><dl><div><dt>Vente HT</dt><dd>${money(item.sale_price)}</dd></div><div><dt>${item.item_type === "service" ? "Unité" : "Disponible"}</dt><dd>${item.item_type === "service" ? esc(item.billing_unit || item.unit) : number(lv.available)}</dd></div></dl></article>`;
        })
        .join("")}</div>`;
    return `<div class="catalog-table-wrap"><table class="catalog-table"><thead><tr><th class="catalog-check"><input type="checkbox" ${rows.every((x) => ui.selected.has(x.id)) ? "checked" : ""} onchange="PilozCatalog.selectPage(this.checked)"></th>${ui.columns
      .map((key) => {
        if (
          (key === "purchase" && !can("view_purchase_prices")) ||
          (key === "margin" && !can("view_margins"))
        )
          return "";
        return `<th><button onclick="PilozCatalog.sort('${key === "designation" ? "name" : key}')">${esc(columnLabels[key])}${ui.sort === (key === "designation" ? "name" : key) ? (ui.direction === "asc" ? " ↑" : " ↓") : ""}</button></th>`;
      })
      .join(
        "",
      )}</tr></thead><tbody>${rows.map((item) => `<tr><td class="catalog-check"><input type="checkbox" ${ui.selected.has(item.id) ? "checked" : ""} onclick="event.stopPropagation()" onchange="PilozCatalog.select('${item.id}',this.checked)"></td>${ui.columns.map((key) => cell(key, item)).join("")}</tr>`).join("")}</tbody></table></div>`;
  }
  function resultsHtml() {
    const rows = filtered(),
      pages = Math.max(1, Math.ceil(rows.length / ui.pageSize));
    ui.page = Math.min(ui.page, pages);
    const start = (ui.page - 1) * ui.pageSize,
      pageRows = rows.slice(start, start + ui.pageSize);
    return `${listRows(pageRows)}<footer class="catalog-pagination"><span>${rows.length ? start + 1 : 0}–${Math.min(start + ui.pageSize, rows.length)} sur ${rows.length}</span><label>Par page <select onchange="PilozCatalog.setPageSize(this.value)">${[25, 50, 100].map((n) => `<option ${ui.pageSize === n ? "selected" : ""}>${n}</option>`).join("")}</select></label><div><button ${ui.page <= 1 ? "disabled" : ""} onclick="PilozCatalog.page(${ui.page - 1})">‹</button><b>${ui.page} / ${pages}</b><button ${ui.page >= pages ? "disabled" : ""} onclick="PilozCatalog.page(${ui.page + 1})">›</button></div></footer>${ui.selected.size ? bulkBar() : ""}`;
  }
  function bulkBar() {
    return `<div class="catalog-bulk"><b>${ui.selected.size} sélectionné${ui.selected.size > 1 ? "s" : ""}</b><button onclick="PilozCatalog.bulkStatus('active')">Activer</button><button onclick="PilozCatalog.bulkStatus('inactive')">Désactiver</button><button onclick="PilozCatalog.openBulkPrice()">Modifier les prix</button><button onclick="PilozCatalog.exportCsv('selected')">Exporter</button><button onclick="PilozCatalog.bulkStatus('archived')">Archiver</button><button class="close" onclick="PilozCatalog.clearSelection()">×</button></div>`;
  }
  function renderList() {
    const s = stats();
    document.getElementById("main").innerHTML =
      `<div class="catalog-workspace">${top()}<section class="catalog-metrics">${metric("Articles actifs", s.products, "products")}${metric("Services actifs", s.services, "services")}${metric("Valeur du stock", s.value, "all", "money")}${metric("En rupture", s.out, "out")}${metric("Sous seuil", s.low, "low")}${metric("Marge moyenne", s.averageMargin, "all", "percent")}${metric("Sans prix", s.noPrice, "no-price")}${metric("Sans fournisseur", s.noSupplier, "all")}</section>${toolbar()}<div id="catalog-results" class="catalog-results">${resultsHtml()}</div></div>`;
  }
  function refreshResults() {
    const node = document.getElementById("catalog-results");
    if (node) node.innerHTML = resultsHtml();
    persist();
  }
  function setSearch(value) {
    ui.query = value;
    ui.page = 1;
    clearTimeout(setSearch.timer);
    setSearch.timer = setTimeout(refreshResults, 120);
  }
  function setQuick(value) {
    ui.quick = value;
    ui.page = 1;
    renderList();
    persist();
  }
  function setFilter(key, value) {
    ui.filters[key] = value;
    ui.page = 1;
    refreshResults();
    document.getElementById("catalog-filter-count").textContent =
      Object.values(ui.filters).filter(Boolean).length || "";
    persist();
  }
  function clearFilters() {
    ui.filters = Object.fromEntries(
      Object.keys(ui.filters).map((key) => [key, ""]),
    );
    ui.quick = "all";
    renderList();
    persist();
  }
  function toggleFilters() {
    const node = document.getElementById("catalog-filters");
    if (node) node.hidden = !node.hidden;
  }
  function sort(key) {
    if (ui.sort === key) ui.direction = ui.direction === "asc" ? "desc" : "asc";
    else {
      ui.sort = key;
      ui.direction = "asc";
    }
    refreshResults();
  }
  function page(value) {
    ui.page = Math.max(1, Number(value) || 1);
    refreshResults();
  }
  function setPageSize(value) {
    ui.pageSize = Number(value) || 25;
    ui.page = 1;
    refreshResults();
  }
  function setView(value) {
    ui.view = value;
    renderList();
    persist();
  }
  function select(id, checked) {
    checked ? ui.selected.add(id) : ui.selected.delete(id);
    refreshResults();
  }
  function selectPage(checked) {
    const rows = filtered().slice(
      (ui.page - 1) * ui.pageSize,
      ui.page * ui.pageSize,
    );
    rows.forEach((x) =>
      checked ? ui.selected.add(x.id) : ui.selected.delete(x.id),
    );
    refreshResults();
  }
  function clearSelection() {
    ui.selected.clear();
    refreshResults();
  }
  function openColumns() {
    modal(
      "Colonnes visibles",
      `<form id="catalog-columns" class="catalog-column-picker">${defaultColumns.map((key) => `<label><input type="checkbox" name="${key}" ${ui.columns.includes(key) ? "checked" : ""}><span>${esc(columnLabels[key])}</span></label>`).join("")}</form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="PilozCatalog.saveColumns()">Appliquer</button>`,
    );
  }
  function saveColumns() {
    const form = document.getElementById("catalog-columns");
    ui.columns = defaultColumns.filter((key) => form.elements[key]?.checked);
    if (!ui.columns.includes("designation")) ui.columns.unshift("designation");
    closeModal();
    renderList();
    persist();
  }
  function openSavedViews() {
    const views = state().data.catalogSavedViews || [];
    modal(
      "Vues enregistrées",
      `<div class="catalog-saved-views">${views.length ? views.map((v) => `<button onclick="PilozCatalog.applySavedView('${v.id}')"><b>${esc(v.name)}</b><small>${Object.values(v.filters || {}).filter(Boolean).length} filtre(s)</small></button>`).join("") : "<p>Aucune vue enregistrée.</p>"}<label class="modern-field"><span>Nom de la nouvelle vue</span><input id="catalog-view-name" placeholder="Ex. Articles à commander"></label></div>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Fermer</button><button class="btn btn-p" onclick="PilozCatalog.saveView()">Enregistrer la vue actuelle</button>`,
    );
  }
  async function saveView() {
    const name = document.getElementById("catalog-view-name")?.value.trim();
    if (!name) return;
    try {
      await api().insert("catalog_saved_views", {
        company_id: state().companyId,
        user_id: global.PilozRuntime.session.user_id,
        name,
        filters: { ...ui.filters, quick: ui.quick, query: ui.query },
        columns: ui.columns,
        sort: { key: ui.sort, direction: ui.direction },
      });
      closeModal();
      await app().refresh();
      notify("Vue enregistrée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function applySavedView(id) {
    const view = (state().data.catalogSavedViews || []).find(
      (x) => x.id === id,
    );
    if (!view) return;
    ui.filters = { ...ui.filters, ...view.filters };
    ui.quick = view.filters?.quick || "all";
    ui.query = view.filters?.query || "";
    ui.columns =
      Array.isArray(view.columns) && view.columns.length
        ? view.columns
        : [...defaultColumns];
    ui.sort = view.sort?.key || "name";
    ui.direction = view.sort?.direction || "asc";
    closeModal();
    renderList();
    persist();
  }
  function modal(title, body, actions = "") {
    closeModal();
    const node = document.createElement("div");
    node.id = "catalog-modal";
    node.className = "catalog-modal-shell";
    node.innerHTML = `<div class="catalog-modal-backdrop" onclick="if(event.target===this)PilozCatalog.closeModal()"><section class="catalog-modal" role="dialog" aria-modal="true"><header><h2>${esc(title)}</h2><button onclick="PilozCatalog.closeModal()" aria-label="Fermer">×</button></header><div class="catalog-modal-body">${body}</div>${actions ? `<footer>${actions}</footer>` : ""}</section></div>`;
    document.body.appendChild(node);
  }
  function closeModal() {
    document.getElementById("catalog-modal")?.remove();
  }
  function field(label, name, value = "", type = "text", attrs = "") {
    return `<label class="modern-field"><span>${esc(label)}</span><input name="${name}" type="${type}" value="${esc(value ?? "")}" ${attrs}></label>`;
  }
  function options(items, value, label = (value) => value.name) {
    return items
      .map(
        (x) =>
          `<option value="${x.id}" ${x.id === value ? "selected" : ""}>${esc(label(x))}</option>`,
      )
      .join("");
  }
  function itemForm(item = {}) {
    const rates = state().data.vatRates || [],
      suppliers = state().data.suppliers || [],
      warehouses = state().data.warehouses || [],
      kind = item.item_type || "product",
      canPurchase = can("view_purchase_prices"),
      canMargin = can("view_margins"),
      purchaseFields = canPurchase
        ? `${field("Prix d’achat HT", "purchase_price", item.purchase_price || 0, "number", 'min="0" step="0.0001" oninput="PilozCatalog.syncPrices()"')}${field("Frais d’approche", "landing_cost", item.landing_cost || 0, "number", 'min="0" step="0.0001" oninput="PilozCatalog.syncPrices()"')}${field("Coût de revient", "cost_price", cost(item), "number", "readonly")}`
        : `<input name="purchase_price" type="hidden" value="0"><input name="landing_cost" type="hidden" value="0"><input name="cost_price" type="hidden" value="0">`,
      marginFields = canMargin
        ? field(
            "Marge cible (%)",
            "margin_rate",
            marginRate(item)?.toFixed(2) || 0,
            "number",
            'step="0.01" oninput="PilozCatalog.syncPrices(\'margin\')"',
          )
        : `<input name="margin_rate" type="hidden" value="0">`,
      marginSummary = canMargin
        ? `<div class="catalog-price-summary"><span>Marge brute <b id="catalog-margin-value">${money(margin(item))}</b></span><span>Taux de marque <b id="catalog-mark-rate">${Number(item.sale_price) ? number((margin(item) / Number(item.sale_price)) * 100) + " %" : "—"}</b></span></div>`
        : `<div id="catalog-margin-value" hidden></div><div id="catalog-mark-rate" hidden></div>`;
    return `<form id="catalog-item-form" class="catalog-form" onsubmit="event.preventDefault();PilozCatalog.saveItem('${item.id || ""}')"><section><h2>Informations générales</h2><div class="catalog-form-grid"><label class="modern-field"><span>Type *</span><select name="item_type" onchange="PilozCatalog.syncItemType(this.value)">${Object.entries(
      typeLabels,
    )
      .map(
        ([k, v]) =>
          `<option value="${k}" ${kind === k ? "selected" : ""}>${v}</option>`,
      )
      .join(
        "",
      )}</select></label>${field("Référence interne", "reference", item.reference, "text", 'placeholder="Générée automatiquement si vide"')}${field("Désignation *", "name", item.name, "text", "required")}${field("Marque", "brand", item.brand)}${field("Référence fabricant", "manufacturer_reference", item.manufacturer_reference)}${unitField("Unité", "unit", item.unit || "unité")}${unitOptions()}<label class="modern-field"><span>Statut</span><select name="status">${Object.entries(
      statusLabels,
    )
      .map(
        ([k, v]) =>
          `<option value="${k}" ${statusOf(item) === k ? "selected" : ""}>${v}</option>`,
      )
      .join(
        "",
      )}</select></label><label class="modern-field full"><span>Description</span><textarea name="sales_description" rows="4">${esc(item.sales_description || item.short_description || item.detailed_description || "")}</textarea><small>Cette description sera reprise automatiquement dans les devis et les factures.</small></label><label class="modern-field full"><span>Note interne</span><textarea name="internal_notes" rows="3">${esc(item.internal_notes || "")}</textarea></label></div></section><section><h2>Prix et marge</h2><div class="catalog-form-grid">${purchaseFields}${marginFields}${field("Prix de vente HT", "sale_price", item.sale_price || 0, "number", 'min="0" step="0.0001" oninput="PilozCatalog.syncPrices(\'sale\')"')}<label class="modern-field"><span>TVA</span><select name="tax_rate" onchange="PilozCatalog.syncPrices()">${(rates.length ? rates : [{ rate: 20, label: "20 %" }]).map((x) => `<option value="${Number(x.rate)}" ${Number(item.tax_rate ?? 20) === Number(x.rate) ? "selected" : ""}>${esc(x.label)}</option>`).join("")}</select></label>${field("Prix de vente TTC", "sale_price_ttc", (Number(item.sale_price || 0) * (1 + Number(item.tax_rate ?? 20) / 100)).toFixed(2), "number", "readonly")}${marginSummary}</div></section><section id="catalog-product-fields" ${kind === "service" ? "hidden" : ""}><h2>Stock et logistique</h2><div class="catalog-form-grid"><label class="modern-field catalog-check-field"><input name="stock_managed" type="checkbox" ${item.stock_managed ? "checked" : ""}><span>Gérer le stock</span></label><label class="modern-field catalog-check-field"><input name="track_lots" type="checkbox" ${item.track_lots ? "checked" : ""}><span>Suivi par lots</span></label><label class="modern-field catalog-check-field"><input name="track_serials" type="checkbox" ${item.track_serials ? "checked" : ""}><span>Suivi par numéros de série</span></label>${field("Seuil d’alerte", "reorder_point", item.reorder_point || 0, "number", 'step="0.0001"')}${field("Stock minimum", "minimum_stock", item.minimum_stock || 0, "number", 'step="0.0001"')}${field("Stock initial", "initial_stock", 0, "number", 'min="0" step="0.0001"')}<label class="modern-field"><span>Entrepôt initial</span><select name="warehouse_id"><option value="">Aucun</option>${options(warehouses, item.default_warehouse_id)}</select></label>${field("Délai d’approvisionnement (jours)", "supply_lead_days", item.supply_lead_days, "number", 'min="0"')}${field("Poids", "weight", item.weight, "number", 'min="0" step="0.0001"')}${field("Pays d’origine", "country_of_origin", item.country_of_origin)}${field("Code douanier", "customs_code", item.customs_code)}</div></section><section id="catalog-service-fields" ${kind !== "service" ? "hidden" : ""}><h2>Prestation</h2><div class="catalog-form-grid">${unitField("Unité de facturation", "billing_unit", item.billing_unit || item.unit || "heure")}${field("Durée estimée (minutes)", "estimated_duration_minutes", item.estimated_duration_minutes, "number", 'min="0"')}${field("Minimum facturable (minutes)", "minimum_billable_minutes", item.minimum_billable_minutes, "number", 'min="0"')}${field("Intervalle de facturation", "billing_interval", item.billing_interval)}<label class="modern-field catalog-check-field"><input name="recurring" type="checkbox" ${item.recurring ? "checked" : ""}><span>Service récurrent</span></label></div></section><section><h2>Fournisseur principal</h2><div class="catalog-form-grid"><label class="modern-field"><span>Fournisseur</span><select name="primary_supplier_id"><option value="">Aucun</option>${options(suppliers, item.primary_supplier_id, (x) => x.legal_name)}</select></label>${field("Référence fournisseur", "supplier_reference", item.supplier_reference)}</div></section><footer class="catalog-form-actions"><button type="button" class="btn btn-o" onclick="${item.id ? `PilozApp.go('sales/items/${item.id}')` : `PilozApp.go('sales/catalog')`}">Annuler</button><button type="submit" class="btn btn-p" data-catalog-save>${item.id ? "Enregistrer les modifications" : "Créer l’élément"}</button></footer></form>`;
  }
  function renderCreate() {
    document.getElementById("main").innerHTML =
      `<div class="catalog-workspace catalog-editor-page"><header class="catalog-detail-nav"><button onclick="PilozApp.go('sales/catalog')">← Retour au catalogue</button><div><span>Nouvel élément</span><h1>Créer un article ou service</h1></div></header>${itemForm()}</div>`;
    setTimeout(() => {
      syncPrices();
      mountEditorEnhancements({});
    }, 0);
  }
  function openEditor(id) {
    const item = catalog().find((x) => x.id === id);
    if (!item) return;
    document.getElementById("main").innerHTML =
      `<div class="catalog-workspace catalog-editor-page"><header class="catalog-detail-nav"><button onclick="PilozApp.go('sales/items/${id}')">← Retour à la fiche</button><div><span>Modification</span><h1>${esc(item.name)}</h1></div></header>${itemForm(item)}</div>`;
    setTimeout(() => {
      syncPrices();
      mountEditorEnhancements(item);
    }, 0);
  }
  function mountEditorEnhancements(item) {
    const form = document.getElementById("catalog-item-form");
    if (!form) return;
    const assigned = new Set(
        (state().data.itemTagAssignments || [])
          .filter((row) => row.item_id === item.id)
          .map((row) => row.tag_id),
      ),
      tags = state().data.itemTags || [],
      anchor = form.elements.available_from?.closest("label");
    if (anchor && !form.querySelector(".catalog-tag-selector"))
      anchor.insertAdjacentHTML(
        "afterend",
        `<fieldset class="catalog-tag-selector full"><legend>Tags</legend>${
          tags.length
            ? tags
                .map(
                  (tag) =>
                    `<label style="--tag:${esc(tag.color || "#E7F5F3")}"><input type="checkbox" name="tag_ids" value="${tag.id}" ${assigned.has(tag.id) ? "checked" : ""}><span>${esc(tag.name)}</span></label>`,
                )
                .join("")
            : "<small>Créez vos tags depuis « Catégories & tags ».</small>"
        }</fieldset>`,
      );
    form.elements.category_id?.addEventListener("change", (event) =>
      applyCategoryDefaults(event.target.value),
    );
  }
  function syncItemType(type) {
    document.getElementById("catalog-product-fields").hidden =
      type === "service";
    document.getElementById("catalog-service-fields").hidden =
      type !== "service";
  }
  function applyCategoryDefaults(categoryId) {
    const form = document.getElementById("catalog-item-form"),
      category = (state().data.categories || []).find(
        (row) => row.id === categoryId,
      );
    if (!form || !category) return;
    if (category.default_unit) form.elements.unit.value = category.default_unit;
    if (category.default_tax_rate != null)
      form.elements.tax_rate.value = Number(category.default_tax_rate);
    if (category.default_stock_managed != null && form.elements.stock_managed)
      form.elements.stock_managed.checked = !!category.default_stock_managed;
    if (category.default_supplier_id)
      form.elements.primary_supplier_id.value = category.default_supplier_id;
    if (category.default_margin_rate != null)
      form.elements.margin_rate.value = Number(category.default_margin_rate);
    syncPrices(category.default_margin_rate != null ? "margin" : "");
  }
  function syncPrices(source = "") {
    const form = document.getElementById("catalog-item-form");
    if (!form) return;
    const purchase = Number(form.elements.purchase_price.value) || 0,
      landing = Number(form.elements.landing_cost.value) || 0,
      costValue = purchase + landing;
    form.elements.cost_price.value = costValue.toFixed(4);
    if (source === "margin")
      form.elements.sale_price.value = (
        costValue *
        (1 + (Number(form.elements.margin_rate.value) || 0) / 100)
      ).toFixed(4);
    const sale = Number(form.elements.sale_price.value) || 0;
    if (source === "sale")
      form.elements.margin_rate.value = costValue
        ? (((sale - costValue) / costValue) * 100).toFixed(2)
        : "0.00";
    const tax = Number(form.elements.tax_rate.value) || 0;
    form.elements.sale_price_ttc.value = (sale * (1 + tax / 100)).toFixed(2);
    const m = sale - costValue;
    document.getElementById("catalog-margin-value").textContent = money(m);
    document.getElementById("catalog-mark-rate").textContent = sale
      ? number((m / sale) * 100) + " %"
      : "—";
  }
  function formPayload(form) {
    const raw = Object.fromEntries(new FormData(form));
    const numeric = [
      "purchase_price",
      "landing_cost",
      "cost_price",
      "sale_price",
      "tax_rate",
      "reorder_point",
      "minimum_stock",
      "supply_lead_days",
      "weight",
      "estimated_duration_minutes",
      "minimum_billable_minutes",
    ];
    numeric.forEach(
      (key) => (raw[key] = raw[key] === "" ? null : Number(raw[key])),
    );
    raw.short_description = raw.sales_description || null;
    for (const removedField of [
      "barcode",
      "category_id",
      "subcategory",
      "available_from",
      "aliases",
      "detailed_description",
    ])
      if (!form.elements.namedItem(removedField)) delete raw[removedField];
    raw.active = !["inactive", "archived", "discontinued"].includes(raw.status);
    raw.stock_managed =
      raw.item_type !== "service" && form.elements.stock_managed?.checked;
    raw.track_lots = !!form.elements.track_lots?.checked;
    raw.track_serials = !!form.elements.track_serials?.checked;
    raw.recurring = !!form.elements.recurring?.checked;
    for (const key of [
      "sale_price_ttc",
      "margin_rate",
      "initial_stock",
      "warehouse_id",
      "primary_supplier_id",
      "supplier_reference",
    ])
      delete raw[key];
    return raw;
  }
  async function saveItem(id = "") {
    const form = document.getElementById("catalog-item-form");
    if (ui.busy || !form?.reportValidity()) return;
    ui.busy = true;
    form.querySelector("[data-catalog-save]").disabled = true;
    const raw = Object.fromEntries(new FormData(form)),
      payload = formPayload(form),
      initialStock = Number(raw.initial_stock) || 0,
      warehouseId = raw.warehouse_id || null,
      primarySupplier = raw.primary_supplier_id || null,
      hasTagField = !!form.elements.namedItem("tag_ids"),
      tagIds = new Set(new FormData(form).getAll("tag_ids").filter(Boolean));
    if (!id && initialStock > 0 && !warehouseId) {
      notify("Sélectionnez un entrepôt pour le stock initial.", "error");
      ui.busy = false;
      form.querySelector("[data-catalog-save]").disabled = false;
      return;
    }
    try {
      let itemId = id;
      if (id) {
        const previous = catalog().find((x) => x.id === id),
          patch = {
            ...payload,
            primary_supplier_id: primarySupplier || null,
            supplier_reference: raw.supplier_reference || null,
          };
        for (const key of [
          "purchase_price",
          "landing_cost",
          "cost_price",
          "sale_price",
        ])
          delete patch[key];
        await api().update("catalog_items", id, patch);
        if (
          Number(raw.sale_price) !== Number(previous?.sale_price) ||
          Number(raw.purchase_price) !== Number(previous?.purchase_price) ||
          Number(raw.landing_cost) !== Number(previous?.landing_cost)
        )
          await api().rpc("change_catalog_price", {
            target_item_id: id,
            target_purchase_price: Number(raw.purchase_price) || 0,
            target_landing_cost: Number(raw.landing_cost) || 0,
            target_sale_price: Number(raw.sale_price) || 0,
            target_effective_from: new Date().toISOString().slice(0, 10),
            target_reason: "Modification de la fiche",
            target_source: "manual",
          });
      } else {
        const suppliers = primarySupplier
          ? [
              {
                supplier_id: primarySupplier,
                supplier_reference: raw.supplier_reference || null,
                purchase_price: Number(raw.purchase_price) || 0,
                is_primary: true,
              },
            ]
          : [];
        itemId = await api().rpc("create_catalog_item", {
          target_company_id: state().companyId,
          target_item: payload,
          target_suppliers: suppliers,
          target_variants: [],
        });
        if (!itemId) throw new Error("Identifiant du nouvel élément absent.");
        if (initialStock > 0)
          await api().rpc("post_stock_movement", {
            target_company_id: state().companyId,
            target_item_id: itemId,
            target_movement_type: "opening",
            target_quantity: initialStock,
            target_unit: payload.unit || "unité",
            destination_warehouse_id: warehouseId,
            movement_reason: "Stock initial",
            target_unit_cost: payload.cost_price || 0,
          });
      }
      if (hasTagField) {
        const existingTags = (state().data.itemTagAssignments || []).filter(
          (row) => row.item_id === itemId,
        );
        for (const assignment of existingTags)
          if (!tagIds.has(assignment.tag_id))
            await api().remove("item_tag_assignments", assignment.id);
        const existingTagIds = new Set(existingTags.map((row) => row.tag_id));
        const missingTags = [...tagIds].filter(
          (tagId) => !existingTagIds.has(tagId),
        );
        if (missingTags.length)
          await api().insert(
            "item_tag_assignments",
            missingTags.map((tagId) => ({
              company_id: state().companyId,
              item_id: itemId,
              tag_id: tagId,
            })),
          );
      }
      await app().refresh();
      notify(id ? "Fiche mise à jour." : "Élément créé.", "success");
      app().go(`sales/items/${itemId}`);
    } catch (error) {
      console.error("[PILOZ Catalogue] Enregistrement impossible", {
        code: error?.code || "",
        message: error?.message || String(error),
      });
      notify(
        error.message ||
          "Enregistrement impossible. Les informations ont été conservées.",
        "error",
      );
    } finally {
      ui.busy = false;
      form.querySelector("[data-catalog-save]")?.removeAttribute("disabled");
    }
  }
  function detailTabs(item) {
    const tabs = [
      ["summary", "Résumé"],
      ["information", "Informations"],
      ["prices", "Prix et marges"],
      ...(item.item_type === "service"
        ? []
        : [
            ["variants", "Variantes"],
            ["stock", "Stock"],
            ["suppliers", "Fournisseurs"],
          ]),
      ["sales", "Ventes"],
      ["purchases", "Achats"],
      ["accounting", "Comptabilité"],
      ["documents", "Documents"],
      ["notes", "Notes"],
      ["history", "Historique"],
    ];
    return `<nav class="catalog-detail-tabs">${tabs.map(([key, label]) => `<button class="${ui.tab === key ? "active" : ""}" onclick="PilozCatalog.setTab('${key}')">${label}</button>`).join("")}</nav>`;
  }
  function detailHeader(item) {
    const lv = levels(item.id),
      sup = supplier(item),
      imageUrl =
        state().data.catalogImageUrls?.[item.id] || item.image_path || "",
      safeImage = /^(https?:|data:image\/|blob:)/i.test(String(imageUrl));
    return `<header class="catalog-detail-header"><div class="catalog-detail-title"><button onclick="PilozApp.go('sales/catalog')">← Catalogue</button><div class="catalog-item-avatar" data-catalog-avatar="${item.id}">${safeImage ? `<img src="${esc(imageUrl)}" alt="">` : esc((item.name || "?").slice(0, 2).toUpperCase())}</div><div><div><span class="catalog-type">${esc(typeLabels[item.item_type])}</span><span class="catalog-status ${statusOf(item)}">${esc(statusLabels[statusOf(item)])}</span></div><h1>${esc(item.name)}</h1><p>${esc(item.reference || "Sans référence")}</p></div></div><div class="catalog-detail-actions"><button class="btn btn-o" onclick="PilozCatalog.addToDocument('${item.id}','quote')">Ajouter à un devis</button><button class="btn btn-o" onclick="PilozCatalog.addToDocument('${item.id}','invoice')">Ajouter à une facture</button>${item.item_type !== "service" ? `<button class="btn btn-o" onclick="PilozCatalog.addToPurchase('${item.id}')">Commander</button><button class="btn btn-o" onclick="PilozCatalog.adjustStock('${item.id}')">Ajuster le stock</button>` : ""}<button class="btn btn-p" onclick="PilozCatalog.openEditor('${item.id}')">Modifier</button><button class="catalog-more" onclick="PilozCatalog.openItemActions('${item.id}')">•••</button></div><dl><div><dt>Prix de vente HT</dt><dd>${money(item.sale_price)}</dd></div>${can("view_purchase_prices") ? `<div><dt>Coût de revient</dt><dd>${money(cost(item))}</dd></div>` : ""}${can("view_margins") ? `<div><dt>Marge</dt><dd>${money(margin(item))}<small>${marginRate(item) === null ? "—" : number(marginRate(item)) + " %"}</small></dd></div>` : ""}<div><dt>TVA</dt><dd>${number(item.tax_rate)} %</dd></div>${item.item_type !== "service" ? `<div><dt>Stock disponible</dt><dd>${item.stock_managed ? number(lv.available) : "Non géré"}</dd></div>` : ""}<div><dt>Fournisseur principal</dt><dd>${esc(sup?.legal_name || "—")}</dd></div><div><dt>Dernière modification</dt><dd>${date(item.updated_at)}</dd></div></dl></header>`;
  }
  function summaryTab(item) {
    const lv = levels(item.id),
      docs = itemDocuments(item.id),
      sales = docs.filter((x) =>
        ["invoice", "credit_note"].includes(x.document_type),
      ),
      quotes = docs.filter((x) => x.document_type === "quote"),
      suppliers = itemSuppliers(item.id);
    return `<div class="catalog-summary-grid"><section class="catalog-panel"><h2>Vue d’ensemble</h2><dl class="catalog-info-list"><div><dt>Désignation</dt><dd>${esc(item.name)}</dd></div><div><dt>Référence</dt><dd>${esc(item.reference)}</dd></div><div><dt>Unité</dt><dd>${esc(item.unit)}</dd></div><div><dt>Statut</dt><dd>${esc(statusLabels[statusOf(item)])}</dd></div></dl></section><section class="catalog-panel"><h2>Activité commerciale</h2><div class="catalog-mini-kpis"><div><span>Devis</span><b>${quotes.length}</b></div><div><span>Factures</span><b>${sales.length}</b></div><div><span>CA HT</span><b>${money(sales.filter((x) => x.document.status !== "draft").reduce((n, x) => n + Number(x.line.total_excl_tax || 0), 0))}</b></div><div><span>Fournisseurs</span><b>${suppliers.length}</b></div></div></section>${item.item_type !== "service" ? `<section class="catalog-panel full"><h2>Stock</h2><div class="catalog-stock-kpis"><div><span>Physique</span><b>${number(lv.physical)}</b></div><div><span>Réservé</span><b>${number(lv.reserved)}</b></div><div><span>Disponible</span><b>${number(lv.available)}</b></div><div><span>À recevoir</span><b>${number(lv.expected)}</b></div><div><span>En transit</span><b>${number(lv.transit)}</b></div></div></section>` : ""}<section class="catalog-panel full"><h2>Description</h2><p class="catalog-copy">${esc(item.sales_description || item.short_description || item.detailed_description || "Aucune description.")}</p></section></div>`;
  }
  function informationTab(item) {
    return `<section class="catalog-panel"><div class="catalog-panel-head"><h2>Informations générales</h2><button class="btn btn-o" onclick="PilozCatalog.openEditor('${item.id}')">Modifier</button></div><dl class="catalog-info-list two"><div><dt>Type</dt><dd>${esc(typeLabels[item.item_type])}</dd></div><div><dt>Référence interne</dt><dd>${esc(item.reference)}</dd></div><div><dt>Référence fabricant</dt><dd>${esc(item.manufacturer_reference || "—")}</dd></div><div><dt>Marque</dt><dd>${esc(item.brand || "—")}</dd></div><div><dt>Unité</dt><dd>${esc(item.unit || "—")}</dd></div><div><dt>Statut</dt><dd>${esc(statusLabels[statusOf(item)])}</dd></div></dl><h3>Description</h3><p class="catalog-copy">${esc(item.sales_description || item.short_description || item.detailed_description || "Aucune description.")}</p><h3>Note interne</h3><p class="catalog-copy muted">${esc(item.internal_notes || "Aucune note interne.")}</p></section>`;
  }
  function pricesTab(item) {
    const histories = (state().data.itemPriceHistory || []).filter(
        (x) => x.item_id === item.id,
      ),
      lists = (state().data.priceListItems || []).filter(
        (x) => x.item_id === item.id,
      ),
      canPurchase = can("view_purchase_prices"),
      canMargin = can("view_margins"),
      canPrice = can("catalog_price_write");
    return `<div class="catalog-summary-grid"><section class="catalog-panel"><div class="catalog-panel-head"><h2>Prix et marge actuels</h2>${canPrice ? `<button class="btn btn-p" onclick="PilozCatalog.openPrice('${item.id}')">Modifier le prix</button>` : ""}</div><dl class="catalog-info-list">${canPurchase ? `<div><dt>Prix d’achat HT</dt><dd>${money(item.purchase_price)}</dd></div><div><dt>Frais d’approche</dt><dd>${money(item.landing_cost)}</dd></div><div><dt>Coût de revient</dt><dd>${money(cost(item))}</dd></div>` : ""}<div><dt>Prix de vente HT</dt><dd>${money(item.sale_price)}</dd></div><div><dt>Prix TTC</dt><dd>${money(Number(item.sale_price) * (1 + Number(item.tax_rate) / 100))}</dd></div>${canMargin ? `<div><dt>Marge brute</dt><dd>${money(margin(item))}</dd></div><div><dt>Taux de marge</dt><dd>${marginRate(item) === null ? "—" : number(marginRate(item)) + " %"}</dd></div><div><dt>Taux de marque</dt><dd>${Number(item.sale_price) ? number((margin(item) / Number(item.sale_price)) * 100) + " %" : "—"}</dd></div>` : ""}</dl></section><section class="catalog-panel"><div class="catalog-panel-head"><h2>Grilles tarifaires</h2>${canPrice ? `<button class="btn btn-o" onclick="PilozCatalog.openPriceList('${item.id}')">Ajouter</button>` : ""}</div>${
      lists.length
        ? `<ul class="catalog-simple-list">${lists
            .map((row) => {
              const list = (state().data.priceLists || []).find(
                (x) => x.id === row.price_list_id,
              );
              return `<li><div><b>${esc(list?.name || "Grille")}</b><small>${row.fixed_price != null ? money(row.fixed_price) : number(row.discount_rate) + " % de remise"}</small></div></li>`;
            })
            .join("")}</ul>`
        : '<p class="catalog-empty-inline">Aucune grille tarifaire liée.</p>'
    }</section><section class="catalog-panel full"><h2>Historique des prix</h2>${historyTable(histories, canPurchase, canMargin)}</section></div>`;
  }
  function historyTable(rows, canPurchase = true, canMargin = true) {
    return rows.length
      ? `<div class="catalog-subtable"><table><thead><tr><th>Date d’effet</th>${canPurchase ? "<th>Achat</th><th>Coût</th>" : ""}<th>Vente</th>${canMargin ? "<th>Marge</th>" : ""}<th>Source</th><th>Motif</th></tr></thead><tbody>${rows.map((x) => `<tr><td>${date(x.effective_from)}</td>${canPurchase ? `<td>${money(x.new_purchase_price)}</td><td>${money(x.new_cost_price)}</td>` : ""}<td>${money(x.new_sale_price)}</td>${canMargin ? `<td>${money(x.new_margin)}</td>` : ""}<td>${esc(x.source)}</td><td>${esc(x.reason || "—")}</td></tr>`).join("")}</tbody></table></div>`
      : '<p class="catalog-empty-inline">Aucun historique antérieur n’a été inventé. Les prochains changements apparaîtront ici.</p>';
  }
  function variantsTab(item) {
    const rows = (state().data.itemVariants || []).filter(
      (x) => x.item_id === item.id,
    );
    return `<section class="catalog-panel"><div class="catalog-panel-head"><div><h2>Variantes</h2><p>Références, codes-barres, prix et stock propres à chaque combinaison.</p></div><div class="catalog-top-actions"><button class="btn btn-o" onclick="PilozCatalog.openVariantMatrix('${item.id}')">Générer une matrice</button><button class="btn btn-p" onclick="PilozCatalog.openVariant('${item.id}')">Ajouter une variante</button></div></div>${
      rows.length
        ? `<div class="catalog-subtable"><table><thead><tr><th>Variante</th><th>Attributs</th><th>Référence</th><th>Code-barres</th>${can("view_purchase_prices") ? "<th>Achat</th>" : ""}<th>Vente</th><th>Statut</th></tr></thead><tbody>${rows
            .map(
              (x) =>
                `<tr><td><b>${esc(x.name)}</b></td><td>${esc(
                  Object.entries(x.attribute_values || {})
                    .map(([k, v]) => `${k}: ${v}`)
                    .join(" · "),
                )}</td><td>${esc(x.reference)}</td><td>${esc(x.barcode || "—")}</td>${can("view_purchase_prices") ? `<td>${money(x.purchase_price ?? item.purchase_price)}</td>` : ""}<td>${money(x.sale_price ?? item.sale_price)}</td><td><span class="catalog-status ${x.is_active ? "active" : "inactive"}">${x.is_active ? "Active" : "Inactive"}</span></td></tr>`,
            )
            .join("")}</tbody></table></div>`
        : '<div class="catalog-empty"><b>Article simple</b><p>Ajoutez des variantes uniquement si les déclinaisons ont leurs propres références ou stocks.</p></div>'
    }</section>`;
  }
  function itemSuppliers(itemId) {
    return (state().data.supplierItems || [])
      .filter((x) => x.catalog_item_id === itemId)
      .map((link) => ({
        ...link,
        supplier: (state().data.suppliers || []).find(
          (x) => x.id === link.supplier_id,
        ),
      }));
  }
  function suppliersTab(item) {
    const rows = itemSuppliers(item.id);
    return `<section class="catalog-panel"><div class="catalog-panel-head"><div><h2>Fournisseurs</h2><p>Un seul fournisseur principal est autorisé par article.</p></div><button class="btn btn-p" onclick="PilozCatalog.openSupplier('${item.id}')">Ajouter un fournisseur</button></div>${rows.length ? `<div class="catalog-subtable"><table><thead><tr><th>Fournisseur</th><th>Référence</th><th>Désignation</th>${can("view_purchase_prices") ? "<th>Prix HT</th>" : ""}<th>Minimum</th><th>Délai</th><th>Validité</th><th></th></tr></thead><tbody>${rows.map((x) => `<tr><td><b>${esc(x.supplier?.legal_name || "—")}</b>${x.is_primary ? "<small>Principal</small>" : ""}</td><td>${esc(x.supplier_reference || "—")}</td><td>${esc(x.supplier_designation || "—")}</td>${can("view_purchase_prices") ? `<td>${money(x.purchase_price)}</td>` : ""}<td>${number(x.minimum_order_quantity || 0)}</td><td>${x.lead_days ?? "—"} j</td><td>${x.valid_until ? date(x.valid_until) : "—"}</td><td>${x.is_primary ? "" : `<button onclick="PilozCatalog.makePrimarySupplier('${item.id}','${x.id}')">Définir principal</button>`}</td></tr>`).join("")}</tbody></table></div>` : '<div class="catalog-empty"><b>Aucun fournisseur</b><p>Ajoutez un fournisseur avec son tarif et son délai.</p></div>'}</section>`;
  }
  function stockTab(item) {
    const levelRows = (state().data.levels || []).filter(
        (x) => x.item_id === item.id,
      ),
      moves = (state().data.movements || [])
        .filter((x) => x.item_id === item.id)
        .slice(0, 100);
    return `<div class="catalog-summary-grid"><section class="catalog-panel full"><div class="catalog-panel-head"><h2>Stock par entrepôt</h2><button class="btn btn-p" onclick="PilozCatalog.adjustStock('${item.id}')">Nouveau mouvement</button></div><div class="catalog-subtable"><table><thead><tr><th>Entrepôt</th><th>Emplacement</th><th>Physique</th><th>Réservé</th><th>Disponible</th><th>À recevoir</th><th>En transit</th></tr></thead><tbody>${levelRows.map((x) => `<tr><td>${esc((state().data.warehouses || []).find((w) => w.id === x.warehouse_id)?.name || "—")}</td><td>${esc((state().data.locations || []).find((l) => l.id === x.location_id)?.code || "—")}</td><td>${number(x.physical_quantity)}</td><td>${number(x.reserved_quantity)}</td><td><b>${number(x.available_quantity)}</b></td><td>${number(x.expected_quantity)}</td><td>${number(x.in_transit_quantity)}</td></tr>`).join("") || '<tr><td colspan="7">Aucun stock enregistré.</td></tr>'}</tbody></table></div></section><section class="catalog-panel full"><h2>Mouvements immuables</h2><div class="catalog-subtable"><table><thead><tr><th>Date</th><th>Type</th><th>Quantité</th><th>Origine</th><th>Destination</th><th>Motif</th></tr></thead><tbody>${moves.map((x) => `<tr><td>${date(x.occurred_at)}</td><td>${esc(x.movement_type)}</td><td>${number(x.quantity)} ${esc(x.unit || "")}</td><td>${esc((state().data.warehouses || []).find((w) => w.id === x.from_warehouse_id)?.name || "—")}</td><td>${esc((state().data.warehouses || []).find((w) => w.id === x.to_warehouse_id)?.name || "—")}</td><td>${esc(x.reason || x.comment || "—")}</td></tr>`).join("") || '<tr><td colspan="6">Aucun mouvement.</td></tr>'}</tbody></table></div></section></div>`;
  }
  function itemDocuments(itemId) {
    const docs = new Map((state().data.documents || []).map((x) => [x.id, x]));
    return (state().data.lines || [])
      .filter((x) => x.item_id === itemId)
      .map((line) => ({ line, document: docs.get(line.document_id) }))
      .filter((x) => x.document);
  }
  function documentTable(rows) {
    return rows.length
      ? `<div class="catalog-subtable"><table><thead><tr><th>Document</th><th>Date</th><th>Client</th><th>Quantité</th><th>Prix HT</th><th>Total HT</th><th>Statut</th></tr></thead><tbody>${rows.map((x) => `<tr onclick="PilozApp.editDocument('${x.document.id}')"><td><b>${esc(x.document.number || "Brouillon")}</b><small>${esc(x.document.document_type)}</small></td><td>${date(x.document.issue_date)}</td><td>${esc(x.document.client?.legal_name || "—")}</td><td>${number(x.line.quantity)}</td><td>${money(x.line.unit_price)}</td><td>${money(x.line.total_excl_tax)}</td><td>${esc(x.document.status)}</td></tr>`).join("")}</tbody></table></div>`
      : '<p class="catalog-empty-inline">Aucune opération.</p>';
  }
  function salesTab(item) {
    const rows = itemDocuments(item.id).filter((x) =>
      ["quote", "invoice", "credit_note", "sales_order"].includes(
        x.document.document_type,
      ),
    );
    return `<section class="catalog-panel"><h2>Historique des ventes et devis</h2>${documentTable(rows)}</section>`;
  }
  function purchasesTab(item) {
    const pol = (state().data.purchaseOrderLines || []).filter(
        (x) => x.item_id === item.id,
      ),
      orders = new Map(
        (state().data.purchaseOrders || []).map((x) => [x.id, x]),
      ),
      receipts = (state().data.goodsReceiptLines || []).filter(
        (x) => x.item_id === item.id,
      );
    return `<div class="catalog-summary-grid"><section class="catalog-panel full"><div class="catalog-panel-head"><h2>Commandes fournisseurs</h2><button class="btn btn-p" onclick="PilozCatalog.addToPurchase('${item.id}')">Créer une commande</button></div><div class="catalog-subtable"><table><thead><tr><th>Commande</th><th>Fournisseur</th><th>Date</th><th>Quantité</th><th>Reçue</th>${can("view_purchase_prices") ? "<th>Prix HT</th>" : ""}<th>Statut</th></tr></thead><tbody>${
      pol
        .map((x) => {
          const order = orders.get(x.purchase_order_id);
          return `<tr><td>${esc(order?.number || "Brouillon")}</td><td>${esc(order?.supplier?.legal_name || "—")}</td><td>${date(order?.order_date)}</td><td>${number(x.quantity)}</td><td>${number(x.received_quantity)}</td>${can("view_purchase_prices") ? `<td>${money(x.unit_price)}</td>` : ""}<td>${esc(order?.status || "—")}</td></tr>`;
        })
        .join("") || '<tr><td colspan="7">Aucun achat.</td></tr>'
    }</tbody></table></div></section><section class="catalog-panel full"><h2>Réceptions</h2><div class="catalog-subtable"><table><thead><tr><th>Date</th><th>Quantité</th>${can("view_purchase_prices") ? "<th>Coût réel</th>" : ""}<th>Entrepôt</th></tr></thead><tbody>${
      receipts
        .map((x) => {
          const receipt = (state().data.receipts || []).find(
            (r) => r.id === x.goods_receipt_id,
          );
          return `<tr><td>${date(receipt?.received_at || receipt?.created_at)}</td><td>${number(x.quantity)}</td>${can("view_purchase_prices") ? `<td>${money(x.unit_cost)}</td>` : ""}<td>${esc((state().data.warehouses || []).find((w) => w.id === receipt?.warehouse_id)?.name || "—")}</td></tr>`;
        })
        .join("") || '<tr><td colspan="4">Aucune réception.</td></tr>'
    }</tbody></table></div></section></div>`;
  }
  function accountingTab(item) {
    const row =
      (state().data.itemAccountingProfiles || []).find(
        (x) => x.item_id === item.id,
      ) || {};
    return `<section class="catalog-panel"><div class="catalog-panel-head"><div><h2>Préparation comptable</h2><p>Ces codes préparent les futurs exports. Ils ne déclenchent aucune écriture comptable.</p></div></div><form id="catalog-accounting-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveAccounting('${item.id}','${row.id || ""}')">${field("Compte de vente", "sales_account_code", row.sales_account_code)}${field("Compte d’achat", "purchase_account_code", row.purchase_account_code)}${field("TVA collectée", "vat_collected_code", row.vat_collected_code)}${field("TVA déductible", "vat_deductible_code", row.vat_deductible_code)}${field("Intracommunautaire", "intracom_code", row.intracom_code)}${field("Export", "export_code", row.export_code)}<div class="full"><button class="btn btn-p" type="submit">Enregistrer</button></div></form></section>`;
  }
  function documentsTab(item) {
    const rows = (state().data.attachments || []).filter(
      (x) => x.entity_type === "catalog_item" && x.entity_id === item.id,
    );
    return `<section class="catalog-panel"><div class="catalog-panel-head"><div><h2>Documents et images</h2><p>Les fichiers internes ne sont jamais ajoutés automatiquement aux PDF clients.</p></div><button class="btn btn-p" onclick="PilozCatalog.openAttachment('${item.id}')">Ajouter un fichier</button></div>${rows.length ? `<ul class="catalog-simple-list">${rows.map((x) => `<li><div><b>${esc(x.file_name)}</b><small>${esc(x.attachment_kind || x.mime_type || "Fichier")} · ${number(Number(x.size_bytes || 0) / 1024)} Ko · ${x.visibility === "client" ? "Visible client" : "Interne"} · ${date(x.created_at)}</small></div><button onclick="PilozCatalog.openAttachmentFile('${x.id}')">Ouvrir</button></li>`).join("")}</ul>` : '<p class="catalog-empty-inline">Aucun fichier lié.</p>'}</section>`;
  }
  function notesTab(item) {
    const rows = (state().data.itemNotes || []).filter(
      (x) => x.item_id === item.id,
    );
    return `<section class="catalog-panel"><div class="catalog-panel-head"><h2>Notes internes</h2><button class="btn btn-p" onclick="PilozCatalog.openNote('${item.id}')">Ajouter une note</button></div>${rows.length ? `<div class="catalog-note-grid">${rows.map((x) => `<article><header><b>${esc(x.title || "Note")}</b>${x.pinned ? "<span>Épinglée</span>" : ""}</header><p>${esc(x.content)}</p><small>${date(x.updated_at || x.created_at)}</small></article>`).join("")}</div>` : '<p class="catalog-empty-inline">Aucune note interne.</p>'}</section>`;
  }
  function historyTab(item) {
    const events = (state().data.itemActivityEvents || []).filter(
        (x) => x.item_id === item.id,
      ),
      prices = (state().data.itemPriceHistory || []).filter(
        (x) => x.item_id === item.id,
      );
    const rows = [
      ...events.map((x) => ({ ...x, label: x.event_type })),
      ...prices.map((x) => ({ ...x, label: "price.changed" })),
    ].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return `<section class="catalog-panel"><h2>Historique unifié</h2>${rows.length ? `<ol class="catalog-timeline">${rows.map((x) => `<li><span></span><div><b>${esc(x.label)}</b><p>${esc(x.reason || x.source || "Application")}</p><small>${date(x.created_at)}</small></div></li>`).join("")}</ol>` : '<p class="catalog-empty-inline">L’historique commence avec la mise en service du nouveau catalogue.</p>'}</section>`;
  }
  function tabContent(item) {
    switch (ui.tab) {
      case "information":
        return informationTab(item);
      case "prices":
        return pricesTab(item);
      case "variants":
        return variantsTab(item);
      case "stock":
        return stockTab(item);
      case "suppliers":
        return suppliersTab(item);
      case "sales":
        return salesTab(item);
      case "purchases":
        return purchasesTab(item);
      case "accounting":
        return accountingTab(item);
      case "documents":
        return documentsTab(item);
      case "notes":
        return notesTab(item);
      case "history":
        return historyTab(item);
      default:
        return summaryTab(item);
    }
  }
  function renderDetail(id) {
    const item = catalog().find((x) => x.id === id);
    if (!item) {
      document.getElementById("main").innerHTML =
        `<div class="catalog-workspace"><div class="catalog-empty"><b>Élément introuvable</b><button class="btn btn-o" onclick="PilozApp.go('sales/catalog')">Retour au catalogue</button></div></div>`;
      return;
    }
    document.getElementById("main").innerHTML =
      `<div class="catalog-workspace catalog-detail">${detailHeader(item)}${detailTabs(item)}<main class="catalog-tab-content">${tabContent(item)}</main></div>`;
    loadCatalogImage(item.id);
  }
  async function loadCatalogImage(itemId) {
    state().data.catalogImageUrls ||= {};
    if (state().data.catalogImageUrls[itemId]) return;
    const image = (state().data.attachments || []).find(
      (row) =>
        row.entity_type === "catalog_item" &&
        row.entity_id === itemId &&
        row.attachment_kind === "main_image",
    );
    if (!image) return;
    try {
      const signed = await api().signedUrl(
        "company-files",
        image.storage_path,
        900,
      );
      const url = signed?.signedURL || signed?.signedUrl || signed?.url;
      if (!url) return;
      state().data.catalogImageUrls[itemId] = url;
      const avatar = document.querySelector(
        `[data-catalog-avatar="${itemId}"]`,
      );
      if (avatar) avatar.innerHTML = `<img src="${esc(url)}" alt="">`;
    } catch {}
  }
  function setTab(tab) {
    ui.tab = tab;
    const match = routePath().match(/^sales\/items\/([^/]+)/);
    if (match) renderDetail(match[1]);
  }
  function openTaxonomy() {
    const settings = state().data.catalogSettings?.[0] || {};
    modal(
      "Paramètres du catalogue",
      `<div class="catalog-taxonomy"><section><h3>Unités</h3><p>Une unité proposée reste toujours modifiable dans un article, un devis ou une facture.</p><form id="catalog-units-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveCatalogUnits()"><label class="modern-field full"><span>Unités proposées (une par ligne)</span><textarea name="units" rows="8" required>${esc(catalogUnits().join("\n"))}</textarea></label><div class="full"><button class="btn btn-p" type="submit">Enregistrer les unités</button></div></form></section><section><h3>Références automatiques</h3><form id="catalog-reference-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveCatalogSettings()">${field("Préfixe article", "product_prefix", settings.product_prefix || "ART")}${field("Préfixe service", "service_prefix", settings.service_prefix || "SER")}${field("Longueur", "reference_padding", settings.reference_padding || 6, "number", 'min="2" max="12"')}${field("Format", "reference_format", settings.reference_format || "{PREFIX}-{NUMBER}")}<label class="modern-field catalog-check-field"><input name="auto_reference" type="checkbox" ${settings.auto_reference !== false ? "checked" : ""}><span>Génération automatique</span></label><label class="modern-field catalog-check-field"><input name="manual_reference_allowed" type="checkbox" ${settings.manual_reference_allowed !== false ? "checked" : ""}><span>Saisie manuelle autorisée</span></label><div class="full"><button class="btn btn-p" type="submit">Enregistrer les références</button></div></form></section></div>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Fermer</button>`,
    );
  }
  async function saveCategory() {
    const form = document.getElementById("catalog-category-form");
    if (!form?.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form));
    try {
      await api().insert("catalog_categories", {
        company_id: state().companyId,
        name: raw.name.trim(),
        description: raw.description || null,
        parent_id: raw.parent_id || null,
        color: raw.color || "#E7F5F3",
        default_tax_rate:
          raw.default_tax_rate === "" ? null : Number(raw.default_tax_rate),
        default_unit: raw.default_unit || null,
        active: true,
      });
      closeModal();
      await app().refresh();
      notify("Catégorie ajoutée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function saveTag() {
    const form = document.getElementById("catalog-tag-form");
    if (!form?.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form));
    try {
      await api().insert("item_tags", {
        company_id: state().companyId,
        name: raw.name.trim(),
        color: raw.color || "#E7F5F3",
        is_active: true,
      });
      closeModal();
      await app().refresh();
      notify("Tag ajouté.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function saveCatalogSettings() {
    const form = document.getElementById("catalog-reference-form");
    if (!form?.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form)),
      payload = {
        company_id: state().companyId,
        product_prefix: raw.product_prefix || "ART",
        service_prefix: raw.service_prefix || "SER",
        reference_padding: Number(raw.reference_padding) || 6,
        reference_format: raw.reference_format || "{PREFIX}-{NUMBER}",
        auto_reference: raw.auto_reference === "on",
        manual_reference_allowed: raw.manual_reference_allowed === "on",
        updated_by: global.PilozRuntime.session.user_id,
      };
    try {
      await api().request(
        "/rest/v1/company_catalog_settings?on_conflict=company_id",
        {
          method: "POST",
          headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
          body: api().serializeBody(payload),
        },
      );
      closeModal();
      await app().refresh();
      notify("Références du catalogue enregistrées.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function saveCatalogUnits() {
    const form = document.getElementById("catalog-units-form");
    if (!form?.reportValidity()) return;
    const units = [
      ...new Set(
        String(form.elements.units.value || "")
          .split(/[\n,;]+/)
          .map((value) => value.trim())
          .filter(Boolean),
      ),
    ];
    if (!units.length) {
      notify("Ajoutez au moins une unité.", "error");
      return;
    }
    try {
      await api().request(
        "/rest/v1/company_catalog_settings?on_conflict=company_id",
        {
          method: "POST",
          headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
          body: api().serializeBody({
            company_id: state().companyId,
            units,
            updated_by: global.PilozRuntime.session.user_id,
          }),
        },
      );
      closeModal();
      await app().refresh();
      notify("Unités du catalogue enregistrées.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openPriceList(itemId) {
    const clients = state().data.clients || [],
      lists = state().data.priceLists || [];
    modal(
      "Ajouter à une grille tarifaire",
      `<form id="catalog-price-list-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.savePriceList('${itemId}')"><label class="modern-field"><span>Grille existante</span><select name="price_list_id"><option value="">Créer une nouvelle grille</option>${options(lists, "")}</select></label>${field("Nom de la nouvelle grille", "name", "", "text", 'placeholder="Ex. Tarif professionnel"')}<label class="modern-field"><span>Client spécifique</span><select name="client_id"><option value="">Tous les clients</option>${options(clients, "", (x) => x.legal_name || x.trade_name || [x.first_name, x.last_name].filter(Boolean).join(" "))}</select></label>${field("Date de début", "valid_from", new Date().toISOString().slice(0, 10), "date")}${field("Date de fin", "valid_until", "", "date")}${field("Priorité", "priority", 0, "number")}${field("Prix fixe HT", "fixed_price", catalog().find((x) => x.id === itemId)?.sale_price || 0, "number", 'min="0" step="0.0001"')}${field("Remise (%)", "discount_rate", "", "number", 'min="0" max="100" step="0.01"')}${field("Coefficient", "coefficient", "", "number", 'min="0" step="0.0001"')}${field("Quantité minimum", "min_quantity", 1, "number", 'min="0.0001" step="0.0001"')}</form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-price-list-form').requestSubmit()">Enregistrer</button>`,
    );
  }
  async function savePriceList(itemId) {
    const form = document.getElementById("catalog-price-list-form");
    if (!form?.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form));
    try {
      let listId = raw.price_list_id;
      if (!listId) {
        if (!raw.name.trim())
          throw new Error("Indiquez le nom de la nouvelle grille.");
        const row = (
          await api().insert("price_lists", {
            company_id: state().companyId,
            name: raw.name.trim(),
            client_id: raw.client_id || null,
            currency: "EUR",
            valid_from: raw.valid_from || null,
            valid_until: raw.valid_until || null,
            priority: Number(raw.priority) || 0,
            is_active: true,
          })
        )[0];
        listId = row.id;
      }
      const itemRow = (
        await api().insert("price_list_items", {
          company_id: state().companyId,
          price_list_id: listId,
          item_id: itemId,
          fixed_price: raw.fixed_price === "" ? null : Number(raw.fixed_price),
          discount_rate:
            raw.discount_rate === "" ? null : Number(raw.discount_rate),
          coefficient: raw.coefficient === "" ? null : Number(raw.coefficient),
        })
      )[0];
      if (Number(raw.min_quantity) > 1)
        await api().insert("price_tiers", {
          company_id: state().companyId,
          price_list_item_id: itemRow.id,
          min_quantity: Number(raw.min_quantity),
          fixed_price: raw.fixed_price === "" ? null : Number(raw.fixed_price),
          discount_rate:
            raw.discount_rate === "" ? null : Number(raw.discount_rate),
          coefficient: raw.coefficient === "" ? null : Number(raw.coefficient),
        });
      closeModal();
      await app().refresh();
      notify("Grille tarifaire enregistrée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openItemActions(id) {
    const item = catalog().find((x) => x.id === id);
    modal(
      "Actions sur la fiche",
      `<div class="catalog-action-list"><button onclick="PilozCatalog.duplicate('${id}')">⧉ <span><b>Dupliquer</b><small>Créer une copie en brouillon avec une nouvelle référence</small></span></button><button onclick="PilozCatalog.changeStatus('${id}','${statusOf(item) === "active" ? "inactive" : "active"}')">◉ <span><b>${statusOf(item) === "active" ? "Désactiver" : "Activer"}</b><small>Conserver la fiche et son historique</small></span></button><button onclick="PilozCatalog.archive('${id}')">⌁ <span><b>Archiver</b><small>Masquer des nouvelles recherches</small></span></button><button class="danger" onclick="PilozCatalog.remove('${id}')">⌫ <span><b>Supprimer si autorisé</b><small>Sinon l’élément sera archivé</small></span></button></div>`,
    );
  }
  async function duplicate(id) {
    try {
      const newId = await api().rpc("duplicate_catalog_item", {
        target_item_id: id,
      });
      closeModal();
      await app().refresh();
      notify("Copie créée en brouillon.", "success");
      app().go(`sales/items/${newId}`);
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function changeStatus(id, status) {
    try {
      await api().update("catalog_items", id, {
        status,
        active: status === "active",
      });
      closeModal();
      await app().refresh();
      notify("Statut mis à jour.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function archive(id) {
    try {
      await api().rpc("archive_or_delete_catalog_item", {
        target_item_id: id,
        target_delete: false,
      });
      closeModal();
      await app().refresh();
      app().go("sales/catalog");
      notify("Élément archivé.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function remove(id) {
    if (
      !confirm(
        "Supprimer définitivement uniquement si cet élément n’a jamais été utilisé ?",
      )
    )
      return;
    try {
      const result = await api().rpc("archive_or_delete_catalog_item", {
        target_item_id: id,
        target_delete: true,
      });
      closeModal();
      await app().refresh();
      app().go("sales/catalog");
      notify(
        result === "deleted"
          ? "Élément supprimé."
          : "Élément utilisé : il a été archivé sans perdre son historique.",
        "success",
      );
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openPrice(id) {
    const item = catalog().find((x) => x.id === id);
    modal(
      "Modifier le prix",
      `<form id="catalog-price-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.savePrice('${id}')">${field("Prix d’achat HT", "purchase_price", item.purchase_price, "number", 'min="0" step="0.0001"')}${field("Frais d’approche", "landing_cost", item.landing_cost, "number", 'min="0" step="0.0001"')}${field("Prix de vente HT", "sale_price", item.sale_price, "number", 'min="0" step="0.0001"')}${field("Date d’effet", "effective_from", new Date().toISOString().slice(0, 10), "date", "required")}${field("Motif", "reason", "", "text", 'placeholder="Ex. Nouveau tarif fournisseur"')}<label class="modern-field"><span>Source</span><select name="source"><option value="manual">Modification manuelle</option><option value="supplier">Fournisseur</option><option value="receipt">Réception</option><option value="bulk">Modification en masse</option><option value="import">Import</option></select></label></form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-price-form').requestSubmit()">Enregistrer</button>`,
    );
  }
  async function savePrice(id) {
    const raw = Object.fromEntries(
      new FormData(document.getElementById("catalog-price-form")),
    );
    try {
      await api().rpc("change_catalog_price", {
        target_item_id: id,
        target_purchase_price: Number(raw.purchase_price) || 0,
        target_landing_cost: Number(raw.landing_cost) || 0,
        target_sale_price: Number(raw.sale_price) || 0,
        target_effective_from: raw.effective_from,
        target_reason: raw.reason || null,
        target_source: raw.source,
      });
      closeModal();
      await app().refresh();
      notify(
        raw.effective_from > new Date().toISOString().slice(0, 10)
          ? "Prix futur programmé."
          : "Prix mis à jour.",
        "success",
      );
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openBulkPrice() {
    modal(
      "Modification des prix en masse",
      `<form id="catalog-bulk-price" class="catalog-form-grid" oninput="PilozCatalog.previewBulkPrice()"><label class="modern-field"><span>Prix concerné</span><select name="target"><option value="sale">Prix de vente</option><option value="purchase">Prix d’achat</option></select></label><label class="modern-field"><span>Opération</span><select name="operation"><option value="percent">Pourcentage</option><option value="amount">Montant fixe</option><option value="coefficient">Coefficient</option></select></label>${field("Valeur", "value", 5, "number", 'step="0.01"')}<label class="modern-field"><span>Sens</span><select name="direction"><option value="increase">Augmenter</option><option value="decrease">Diminuer</option></select></label></form><div id="catalog-bulk-preview"></div>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="PilozCatalog.applyBulkPrice()">Appliquer</button>`,
    );
    previewBulkPrice();
  }
  function previewBulkPrice() {
    const form = document.getElementById("catalog-bulk-price");
    if (!form) return;
    const raw = Object.fromEntries(new FormData(form)),
      rows = catalog().filter((x) => ui.selected.has(x.id)),
      compute = (old) => {
        const value = Number(raw.value) || 0,
          sign = raw.direction === "decrease" ? -1 : 1;
        if (raw.operation === "percent")
          return old * (1 + (sign * value) / 100);
        if (raw.operation === "amount") return Math.max(0, old + sign * value);
        return raw.direction === "decrease"
          ? old / Math.max(value, 0.0001)
          : old * value;
      },
      node = document.getElementById("catalog-bulk-preview");
    node.innerHTML = `<div class="catalog-bulk-preview"><b>${rows.length} élément(s) concerné(s)</b><table><tr><th>Élément</th><th>Ancienne valeur</th><th>Nouvelle valeur</th></tr>${rows
      .slice(0, 8)
      .map((item) => {
        const old =
          raw.target === "sale"
            ? Number(item.sale_price)
            : Number(item.purchase_price);
        return `<tr><td>${esc(item.name)}</td><td>${money(old)}</td><td>${money(compute(old))}</td></tr>`;
      })
      .join(
        "",
      )}</table>${rows.length > 8 ? `<small>Et ${rows.length - 8} autre(s)…</small>` : ""}</div>`;
  }
  async function applyBulkPrice() {
    const raw = Object.fromEntries(
        new FormData(document.getElementById("catalog-bulk-price")),
      ),
      rows = catalog().filter((x) => ui.selected.has(x.id)),
      value = Number(raw.value) || 0,
      operation =
        raw.operation === "percent"
          ? raw.direction === "decrease"
            ? "decrease_percent"
            : "increase_percent"
          : raw.operation === "amount"
            ? "add_amount"
            : "coefficient",
      targetValue =
        raw.operation === "amount" && raw.direction === "decrease"
          ? -value
          : raw.operation === "coefficient" && raw.direction === "decrease"
            ? 1 / Math.max(value, 0.0001)
            : value;
    try {
      await api().rpc("change_catalog_prices_bulk", {
        target_item_ids: rows.map((item) => item.id),
        target_mode: raw.target,
        target_operation: operation,
        target_value: targetValue,
        target_reason: `Modification en masse (${rows.length} éléments)`,
      });
      closeModal();
      ui.selected.clear();
      await app().refresh();
      notify("Prix mis à jour et historisés.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function bulkStatus(status) {
    const rows = [...ui.selected];
    if (!rows.length) return;
    try {
      for (const id of rows)
        status === "archived"
          ? await api().rpc("archive_or_delete_catalog_item", {
              target_item_id: id,
              target_delete: false,
            })
          : await api().update("catalog_items", id, {
              status,
              active: status === "active",
            });
      ui.selected.clear();
      await app().refresh();
      notify(`${rows.length} élément(s) mis à jour.`, "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openSupplier(itemId) {
    const suppliers = state().data.suppliers || [];
    modal(
      "Ajouter un fournisseur",
      `<form id="catalog-supplier-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveSupplier('${itemId}')"><label class="modern-field"><span>Fournisseur *</span><select name="supplier_id" required><option value="">Choisir…</option>${options(suppliers, "", (x) => x.legal_name)}</select></label>${field("Référence fournisseur", "supplier_reference")}${field("Désignation fournisseur", "supplier_designation")}${field("Prix d’achat HT", "purchase_price", 0, "number", 'min="0" step="0.0001"')}${field("Devise", "currency", "EUR")}${field("Quantité minimum", "minimum_order_quantity", 1, "number", 'min="0" step="0.0001"')}${field("Conditionnement", "package_quantity", 1, "number", 'min="0" step="0.0001"')}${field("Délai (jours)", "lead_days", "", "number", 'min="0"')}${field("Frais", "approach_fees", 0, "number", 'min="0" step="0.0001"')}${field("Remise (%)", "discount_rate", 0, "number", 'min="0" max="100" step="0.01"')}${field("Valide jusqu’au", "valid_until", "", "date")}<label class="modern-field catalog-check-field"><input name="is_primary" type="checkbox"><span>Fournisseur principal</span></label></form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-supplier-form').requestSubmit()">Ajouter</button>`,
    );
  }
  async function saveSupplier(itemId) {
    const form = document.getElementById("catalog-supplier-form");
    if (!form.reportValidity()) return;
    const raw = Object.fromEntries(new FormData(form)),
      payload = {
        company_id: state().companyId,
        catalog_item_id: itemId,
        supplier_id: raw.supplier_id,
        supplier_reference: raw.supplier_reference || null,
        supplier_designation: raw.supplier_designation || null,
        purchase_price: Number(raw.purchase_price) || 0,
        currency: raw.currency || "EUR",
        minimum_order_quantity: Number(raw.minimum_order_quantity) || 1,
        package_quantity: Number(raw.package_quantity) || 1,
        lead_days: raw.lead_days === "" ? null : Number(raw.lead_days),
        approach_fees: Number(raw.approach_fees) || 0,
        discount_rate: Number(raw.discount_rate) || 0,
        valid_until: raw.valid_until || null,
        is_primary: raw.is_primary === "on",
        active: true,
      };
    try {
      if (payload.is_primary) {
        for (const link of itemSuppliers(itemId).filter((x) => x.is_primary))
          await api().update("supplier_items", link.id, { is_primary: false });
      }
      await api().insert("supplier_items", payload);
      if (payload.is_primary)
        await api().update("catalog_items", itemId, {
          primary_supplier_id: payload.supplier_id,
          supplier_reference: payload.supplier_reference,
        });
      closeModal();
      await app().refresh();
      notify("Fournisseur ajouté.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function makePrimarySupplier(itemId, linkId) {
    const links = itemSuppliers(itemId),
      target = links.find((x) => x.id === linkId);
    try {
      for (const link of links)
        await api().update("supplier_items", link.id, {
          is_primary: link.id === linkId,
        });
      await api().update("catalog_items", itemId, {
        primary_supplier_id: target.supplier_id,
        supplier_reference: target.supplier_reference,
      });
      await app().refresh();
      notify("Fournisseur principal modifié.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openVariant(itemId) {
    const item = catalog().find((x) => x.id === itemId);
    modal(
      "Ajouter une variante",
      `<form id="catalog-variant-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveVariant('${itemId}')">${field("Nom de la variante", "name", "", "text", 'required placeholder="Ex. Bleu · Taille M"')}${field("Référence", "reference", `${item.reference}-`, "text", "required")}${field("Code-barres", "barcode")}${field("Attributs", "attributes", "", "text", 'placeholder="Couleur=Bleu, Taille=M"')}${field("Prix d’achat HT", "purchase_price", item.purchase_price, "number", 'min="0" step="0.0001"')}${field("Coût de revient", "cost_price", cost(item), "number", 'min="0" step="0.0001"')}${field("Prix de vente HT", "sale_price", item.sale_price, "number", 'min="0" step="0.0001"')}${field("TVA", "tax_rate", item.tax_rate, "number", 'min="0" max="100" step="0.01"')}</form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-variant-form').requestSubmit()">Ajouter</button>`,
    );
  }
  async function saveVariant(itemId) {
    const raw = Object.fromEntries(
        new FormData(document.getElementById("catalog-variant-form")),
      ),
      attributes = Object.fromEntries(
        String(raw.attributes || "")
          .split(",")
          .map((x) => x.split("=").map((v) => v.trim()))
          .filter((x) => x.length === 2),
      );
    try {
      await api().insert("item_variants", {
        company_id: state().companyId,
        item_id: itemId,
        name: raw.name,
        reference: raw.reference,
        barcode: raw.barcode || null,
        attribute_values: attributes,
        purchase_price: Number(raw.purchase_price) || 0,
        cost_price: Number(raw.cost_price) || 0,
        sale_price: Number(raw.sale_price) || 0,
        tax_rate: Number(raw.tax_rate) || 0,
        is_active: true,
        status: "active",
      });
      closeModal();
      await app().refresh();
      notify("Variante ajoutée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function openVariantMatrix(itemId) {
    const item = catalog().find((x) => x.id === itemId);
    modal(
      "Générer les variantes",
      `<form id="catalog-variant-matrix-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.generateVariantMatrix('${itemId}')">${field("Attribut 1", "attribute_1", "Taille", "text", "required")}${field("Valeurs 1", "values_1", "S, M, L", "text", 'required placeholder="Séparées par des virgules"')}${field("Attribut 2", "attribute_2", "Couleur")}${field("Valeurs 2", "values_2", "", "text", 'placeholder="Noir, Blanc"')}${field("Préfixe de référence", "reference_prefix", `${item.reference}-`, "text", "required")}${field("Prix d’achat HT", "purchase_price", item.purchase_price, "number", 'min="0" step="0.0001"')}${field("Coût de revient", "cost_price", cost(item), "number", 'min="0" step="0.0001"')}${field("Prix de vente HT", "sale_price", item.sale_price, "number", 'min="0" step="0.0001"')}${field("TVA", "tax_rate", item.tax_rate, "number", 'min="0" max="100" step="0.01"')}<p class="full catalog-copy muted">Chaque combinaison reçoit sa propre référence. Un maximum de 100 variantes est créé dans une seule opération atomique.</p></form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-variant-matrix-form').requestSubmit()">Générer</button>`,
    );
  }
  async function generateVariantMatrix(itemId) {
    const form = document.getElementById("catalog-variant-matrix-form");
    if (!form?.reportValidity() || ui.busy) return;
    const raw = Object.fromEntries(new FormData(form)),
      values1 = String(raw.values_1 || "")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
      values2 = String(raw.values_2 || "")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
      combinations = values2.length
        ? values1.flatMap((first) => values2.map((second) => [first, second]))
        : values1.map((first) => [first]);
    if (!combinations.length || combinations.length > 100) {
      notify("La matrice doit contenir entre 1 et 100 variantes.", "error");
      return;
    }
    const slug = (value) =>
        String(value)
          .normalize("NFD")
          .replace(/[\u0300-\u036f]/g, "")
          .replace(/[^a-zA-Z0-9]+/g, "-")
          .replace(/^-|-$/g, "")
          .toUpperCase(),
      attributes = [
        { name: raw.attribute_1.trim(), values: values1, position: 0 },
        ...(values2.length
          ? [{ name: raw.attribute_2.trim(), values: values2, position: 1 }]
          : []),
      ],
      variants = combinations.map((values) => {
        const attributeValues = { [raw.attribute_1.trim()]: values[0] };
        if (values[1]) attributeValues[raw.attribute_2.trim()] = values[1];
        return {
          name: values.join(" · "),
          reference: `${raw.reference_prefix}${values.map(slug).join("-")}`,
          attribute_values: attributeValues,
          purchase_price: Number(raw.purchase_price) || 0,
          cost_price: Number(raw.cost_price) || 0,
          sale_price: Number(raw.sale_price) || 0,
          tax_rate: Number(raw.tax_rate) || 0,
        };
      });
    ui.busy = true;
    try {
      await api().rpc("create_catalog_variants", {
        target_item_id: itemId,
        target_attributes: attributes,
        target_variants: variants,
      });
      closeModal();
      await app().refresh();
      notify(`${variants.length} variante(s) créée(s).`, "success");
    } catch (error) {
      notify(error.message || "Création des variantes impossible.", "error");
    } finally {
      ui.busy = false;
    }
  }
  function openAttachment(itemId) {
    modal(
      "Ajouter un fichier",
      `<form id="catalog-attachment-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveAttachment('${itemId}')"><label class="modern-field full"><span>Fichier *</span><input name="file" type="file" accept="image/png,image/jpeg,image/webp,application/pdf,text/plain,text/csv" required></label><label class="modern-field"><span>Type</span><select name="attachment_kind"><option value="main_image">Image principale</option><option value="secondary_image">Image secondaire</option><option value="technical_sheet">Fiche technique</option><option value="manual">Notice</option><option value="certificate">Certificat</option><option value="supplier_document">Document fournisseur</option><option value="internal_document">Fichier interne</option></select></label><label class="modern-field"><span>Visibilité</span><select name="visibility"><option value="internal">Interne uniquement</option><option value="client">Visible côté client si ajouté manuellement</option></select></label><p class="full catalog-copy muted">10 Mo maximum. Un fichier interne ne sera jamais intégré automatiquement dans un PDF client.</p></form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-attachment-form').requestSubmit()">Importer</button>`,
    );
  }
  async function saveAttachment(itemId) {
    const form = document.getElementById("catalog-attachment-form");
    if (!form?.reportValidity() || ui.busy) return;
    const raw = new FormData(form),
      file = raw.get("file"),
      allowed = new Set([
        "image/png",
        "image/jpeg",
        "image/webp",
        "application/pdf",
        "text/plain",
        "text/csv",
      ]);
    if (!(file instanceof File) || !file.size) return;
    if (file.size > 10 * 1024 * 1024 || !allowed.has(file.type)) {
      notify(
        "Fichier refusé : format non autorisé ou taille supérieure à 10 Mo.",
        "error",
      );
      return;
    }
    const extension = (file.name.split(".").pop() || "bin")
        .replace(/[^a-z0-9]/gi, "")
        .toLowerCase(),
      path = `${state().companyId}/catalog/${itemId}/${Date.now()}-${crypto.randomUUID()}.${extension}`;
    ui.busy = true;
    try {
      await api().upload("company-files", path, file, false);
      await api().insert("attachments", {
        company_id: state().companyId,
        entity_type: "catalog_item",
        entity_id: itemId,
        storage_path: path,
        file_name: file.name,
        mime_type: file.type,
        size_bytes: file.size,
        attachment_kind: raw.get("attachment_kind") || "internal_document",
        visibility: raw.get("visibility") || "internal",
      });
      closeModal();
      await app().refresh();
      notify("Fichier ajouté.", "success");
    } catch (error) {
      notify(error.message || "Import du fichier impossible.", "error");
    } finally {
      ui.busy = false;
    }
  }
  async function openAttachmentFile(attachmentId) {
    const row = (state().data.attachments || []).find(
      (attachment) => attachment.id === attachmentId,
    );
    if (!row) return;
    try {
      const signed = await api().signedUrl(
        "company-files",
        row.storage_path,
        900,
      );
      const url = signed?.signedURL || signed?.signedUrl || signed?.url;
      if (url) global.open(url, "_blank", "noopener");
    } catch (error) {
      notify(error.message || "Ouverture du fichier impossible.", "error");
    }
  }
  function openNote(itemId) {
    modal(
      "Ajouter une note interne",
      `<form id="catalog-note-form" class="catalog-form-grid" onsubmit="event.preventDefault();PilozCatalog.saveNote('${itemId}')">${field("Titre", "title")}<label class="modern-field full"><span>Contenu *</span><textarea name="content" rows="6" required></textarea></label><label class="modern-field catalog-check-field"><input name="pinned" type="checkbox"><span>Épingler cette note</span></label></form>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button class="btn btn-p" onclick="document.getElementById('catalog-note-form').requestSubmit()">Ajouter</button>`,
    );
  }
  async function saveNote(itemId) {
    const raw = Object.fromEntries(
      new FormData(document.getElementById("catalog-note-form")),
    );
    try {
      await api().insert("item_notes", {
        company_id: state().companyId,
        item_id: itemId,
        title: raw.title || null,
        content: raw.content,
        pinned: raw.pinned === "on",
      });
      closeModal();
      await app().refresh();
      notify("Note ajoutée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  async function saveAccounting(itemId, id) {
    const raw = Object.fromEntries(
        new FormData(document.getElementById("catalog-accounting-form")),
      ),
      payload = {
        ...raw,
        company_id: state().companyId,
        item_id: itemId,
        is_active: true,
      };
    try {
      id
        ? await api().update("item_accounting_profiles", id, payload)
        : await api().insert("item_accounting_profiles", payload);
      await app().refresh();
      notify("Préparation comptable enregistrée.", "success");
    } catch (error) {
      notify(error.message, "error");
    }
  }
  function addToDocument(itemId, type) {
    app().newDocument(type);
    setTimeout(() => {
      const s = state(),
        index = 0;
      if (global.PilozDocumentEditorV2?.selectItem)
        global.PilozDocumentEditorV2.selectItem(index, itemId);
      else app().selectItem(index, itemId);
    }, 80);
  }
  function addToPurchase(itemId) {
    app().newPurchaseOrder();
    setTimeout(() => {
      const s = state();
      if (s.purchaseDraft?.lines?.[0]) {
        const item = catalog().find((x) => x.id === itemId);
        Object.assign(s.purchaseDraft.lines[0], {
          item_id: itemId,
          unit_price: Number(item.purchase_price) || 0,
          tax_rate: Number(item.tax_rate) || 0,
        });
        app().setPurchaseLine?.(0, "item_id", itemId);
      }
    }, 80);
  }
  function adjustStock(itemId) {
    app().openMovementForm();
    setTimeout(() => {
      const form = document.getElementById("movement-form");
      if (form?.elements.item_id) form.elements.item_id.value = itemId;
    }, 30);
  }
  function exportCsv(scope = "filtered") {
    const rows =
        scope === "selected"
          ? catalog().filter((x) => ui.selected.has(x.id))
          : scope === "all"
            ? catalog()
            : filtered(),
      headers = [
        "type",
        "reference",
        "designation",
        "description",
        "categorie",
        "unite",
        "prix_achat_ht",
        "cout_revient",
        "prix_vente_ht",
        "tva",
        "stock_disponible",
        "stock_reserve",
        "stock_a_recevoir",
        "fournisseur",
        "code_barres",
        "statut",
      ],
      quote = (value) => `"${String(value ?? "").replaceAll('"', '""')}"`,
      lines = [
        headers.join(";"),
        ...rows.map((item) => {
          const lv = levels(item.id);
          return [
            item.item_type,
            item.reference,
            item.name,
            item.sales_description,
            category(item)?.name,
            item.unit,
            item.purchase_price,
            cost(item),
            item.sale_price,
            item.tax_rate,
            lv.available,
            lv.reserved,
            lv.expected,
            supplier(item)?.legal_name,
            item.barcode,
            statusOf(item),
          ]
            .map(quote)
            .join(";");
        }),
      ],
      blob = new Blob(["\ufeff" + lines.join("\r\n")], {
        type: "text/csv;charset=utf-8",
      }),
      url = URL.createObjectURL(blob),
      a = document.createElement("a");
    a.href = url;
    a.download = `catalogue-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
    notify(`${rows.length} élément(s) exporté(s).`, "success");
  }
  function openImport() {
    ui.importRows = [];
    ui.importStep = 1;
    modal(
      "Importer des articles et services",
      `<div id="catalog-import-content">${importStep()}</div>`,
      `<button class="btn btn-o" onclick="PilozCatalog.closeModal()">Annuler</button><button id="catalog-import-next" class="btn btn-p" onclick="PilozCatalog.nextImport()" disabled>Continuer</button>`,
    );
  }
  function importStep() {
    if (ui.importStep === 1)
      return `<div class="catalog-import-drop"><b>Sélectionnez un fichier CSV</b><p>Séparateur virgule ou point-virgule. Une prévisualisation sera affichée avant l’import.</p><input type="file" accept=".csv,text/csv" onchange="PilozCatalog.readImport(this.files[0])"></div>`;
    if (ui.importStep === 2) {
      const headers = Object.keys(ui.importRows[0] || {});
      return `<div class="catalog-import-preview"><h3>Prévisualisation · ${ui.importRows.length} ligne(s)</h3><div class="catalog-subtable"><table><thead><tr>${headers.map((x) => `<th>${esc(x)}</th>`).join("")}</tr></thead><tbody>${ui.importRows
        .slice(0, 8)
        .map(
          (row) =>
            `<tr>${headers.map((x) => `<td>${esc(row[x])}</td>`).join("")}</tr>`,
        )
        .join(
          "",
        )}</tbody></table></div><p>Les colonnes reconnues : type, reference, designation, description, categorie, unite, prix_achat_ht, prix_vente_ht, tva, stock_initial, fournisseur, reference_fournisseur, code_barres, statut.</p><label class="modern-field"><span>En cas de doublon</span><select onchange="PilozCatalog.setImportMode(this.value)"><option value="skip">Ignorer</option><option value="update">Mettre à jour la fiche existante</option><option value="create">Créer avec une nouvelle référence</option></select></label><p>Les doublons sont recherchés par référence, code-barres et désignation exacte. Aucun import partiel n’est masqué : chaque ligne apparaîtra dans le rapport.</p></div>`;
    }
    return `<div class="catalog-import-report"><h3>Rapport d’import</h3><div id="catalog-import-progress">Prêt à importer ${ui.importRows.length} ligne(s).</div></div>`;
  }
  function parseCsv(text) {
    const first = text.split(/\r?\n/)[0] || "",
      separator =
        (first.match(/;/g) || []).length >= (first.match(/,/g) || []).length
          ? ";"
          : ",";
    const parse = (line) => {
        const out = [];
        let value = "",
          quoted = false;
        for (let i = 0; i < line.length; i++) {
          const c = line[i];
          if (c === '"') {
            if (quoted && line[i + 1] === '"') {
              value += '"';
              i++;
            } else quoted = !quoted;
          } else if (c === separator && !quoted) {
            out.push(value.trim());
            value = "";
          } else value += c;
        }
        out.push(value.trim());
        return out;
      },
      lines = text
        .replace(/^\ufeff/, "")
        .split(/\r?\n/)
        .filter(Boolean),
      headers = parse(lines.shift()).map((x) =>
        x
          .toLocaleLowerCase("fr")
          .normalize("NFD")
          .replace(/[\u0300-\u036f]/g, "")
          .replace(/\s+/g, "_"),
      );
    return lines.map((line) =>
      Object.fromEntries(
        parse(line).map((value, i) => [headers[i] || `col_${i + 1}`, value]),
      ),
    );
  }
  function readImport(file) {
    if (!file) return;
    ui.importFileName = file.name || "catalogue.csv";
    const reader = new FileReader();
    reader.onload = () => {
      ui.importRows = parseCsv(String(reader.result || ""));
      document.getElementById("catalog-import-next").disabled =
        !ui.importRows.length;
    };
    reader.readAsText(file, "UTF-8");
  }
  function setImportMode(mode) {
    ui.importMode = ["skip", "update", "create"].includes(mode) ? mode : "skip";
  }
  function nextImport() {
    if (ui.importStep === 1) {
      ui.importStep = 2;
      document.getElementById("catalog-import-content").innerHTML =
        importStep();
      document.getElementById("catalog-import-next").textContent = "Valider";
      return;
    }
    if (ui.importStep === 2) {
      ui.importStep = 3;
      document.getElementById("catalog-import-content").innerHTML =
        importStep();
      document.getElementById("catalog-import-next").textContent = "Importer";
      return;
    }
    runImport();
  }
  async function runImport() {
    if (ui.busy) return;
    ui.busy = true;
    const report = { created: 0, updated: 0, skipped: 0, errors: [] },
      rowReports = [];
    let jobId = null;
    try {
      const job = (
        await api().insert("item_import_jobs", {
          company_id: state().companyId,
          file_name: ui.importFileName,
          status: "processing",
          total_rows: ui.importRows.length,
          mapping: { mode: ui.importMode },
        })
      )[0];
      jobId = job?.id;
      if (!jobId) throw new Error("Le suivi de l’import n’a pas pu être créé.");
      const existing = [...catalog()],
        supplierLinks = state().data.supplierItems || [],
        warehouses = state().data.warehouses || [];
      for (let index = 0; index < ui.importRows.length; index++) {
        const row = ui.importRows[index],
          line = index + 2,
          reference = String(row.reference || "").trim(),
          barcode = String(row.code_barres || row.barcode || "").trim(),
          supplierReference = String(row.reference_fournisseur || "").trim(),
          name = String(row.designation || row.nom || "").trim(),
          source = { ...row };
        try {
          if (!name) throw new Error("Désignation manquante");
          const duplicateLink = supplierReference
              ? supplierLinks.find(
                  (link) =>
                    String(link.supplier_reference || "").toLowerCase() ===
                    supplierReference.toLowerCase(),
                )
              : null,
            duplicate = existing.find(
              (item) =>
                (reference &&
                  String(item.reference || "").toLowerCase() ===
                    reference.toLowerCase()) ||
                (barcode && item.barcode === barcode) ||
                String(item.name || "")
                  .trim()
                  .toLowerCase() === name.toLowerCase() ||
                item.id === duplicateLink?.catalog_item_id,
            );
          if (duplicate && ui.importMode === "skip") {
            report.skipped++;
            rowReports.push({
              company_id: state().companyId,
              import_job_id: jobId,
              row_number: line,
              source_data: source,
              normalized_data: { duplicate_item_id: duplicate.id },
              action: "skip",
              status: "skipped",
              errors: [],
            });
            continue;
          }
          let categoryId = null;
          const categoryName = String(row.categorie || "").trim();
          if (categoryName) {
            let categoryRow = (state().data.categories || []).find(
              (category) =>
                category.name.toLowerCase() === categoryName.toLowerCase(),
            );
            if (!categoryRow)
              categoryRow = (
                await api().insert("catalog_categories", {
                  company_id: state().companyId,
                  name: categoryName,
                  active: true,
                })
              )[0];
            categoryId = categoryRow?.id || null;
          }
          const supplierName = String(row.fournisseur || "").trim(),
            supplier = supplierName
              ? (state().data.suppliers || []).find(
                  (entry) =>
                    entry.legal_name.toLowerCase() ===
                    supplierName.toLowerCase(),
                )
              : null;
          if (supplierName && !supplier)
            throw new Error(`Fournisseur introuvable : ${supplierName}`);
          const stockInitial =
            Number(String(row.stock_initial || 0).replace(",", ".")) || 0;
          if (stockInitial > 0 && !warehouses.length)
            throw new Error(
              "Stock initial impossible : aucun entrepôt configuré",
            );
          const purchase =
              Number(String(row.prix_achat_ht || 0).replace(",", ".")) || 0,
            payload = {
              item_type: String(row.type || "product")
                .toLowerCase()
                .includes("service")
                ? "service"
                : "product",
              reference:
                duplicate && ui.importMode === "create" ? "" : reference,
              name,
              sales_description: row.description || null,
              category_id: categoryId,
              unit: row.unite || "unité",
              purchase_price: purchase,
              cost_price: purchase,
              sale_price:
                Number(String(row.prix_vente_ht || 0).replace(",", ".")) || 0,
              tax_rate: Number(String(row.tva || 20).replace(",", ".")) || 0,
              barcode:
                duplicate && ui.importMode === "create"
                  ? null
                  : barcode || null,
              status: row.statut || "active",
              active: row.statut !== "inactive",
              stock_managed: stockInitial > 0,
              reorder_point:
                Number(String(row.seuil || 0).replace(",", ".")) || 0,
            };
          let itemId;
          if (duplicate && ui.importMode === "update") {
            const patch = { ...payload };
            delete patch.purchase_price;
            delete patch.cost_price;
            delete patch.sale_price;
            if (!reference) delete patch.reference;
            await api().update("catalog_items", duplicate.id, patch);
            await api().rpc("change_catalog_price", {
              target_item_id: duplicate.id,
              target_purchase_price: payload.purchase_price,
              target_landing_cost: Number(duplicate.landing_cost) || 0,
              target_sale_price: payload.sale_price,
              target_effective_from: new Date().toISOString().slice(0, 10),
              target_reason: `Import ${ui.importFileName}`,
              target_source: "import",
            });
            itemId = duplicate.id;
            report.updated++;
          } else {
            itemId = await api().rpc("create_catalog_item", {
              target_company_id: state().companyId,
              target_item: payload,
              target_suppliers: supplier
                ? [
                    {
                      supplier_id: supplier.id,
                      supplier_reference: supplierReference || null,
                      purchase_price: purchase,
                      is_primary: true,
                    },
                  ]
                : [],
              target_variants: [],
            });
            if (!itemId) throw new Error("Identifiant créé absent");
            if (stockInitial > 0)
              await api().rpc("post_stock_movement", {
                target_company_id: state().companyId,
                target_item_id: itemId,
                target_movement_type: "opening",
                target_quantity: stockInitial,
                target_unit: payload.unit,
                destination_warehouse_id: warehouses[0].id,
                movement_reason: `Import ${ui.importFileName}`,
                target_unit_cost: purchase,
              });
            existing.push({ ...payload, id: itemId });
            report.created++;
          }
          rowReports.push({
            company_id: state().companyId,
            import_job_id: jobId,
            row_number: line,
            source_data: source,
            normalized_data: { ...payload, item_id: itemId },
            action: duplicate ? ui.importMode : "create",
            status: "completed",
            errors: [],
          });
        } catch (error) {
          report.errors.push({ line, error: error.message });
          rowReports.push({
            company_id: state().companyId,
            import_job_id: jobId,
            row_number: line,
            source_data: source,
            action: "error",
            status: "error",
            errors: [{ message: error.message }],
          });
        }
      }
      if (rowReports.length) await api().insert("item_import_rows", rowReports);
      await api().update("item_import_jobs", jobId, {
        status: report.errors.length ? "completed_with_errors" : "completed",
        created_count: report.created,
        updated_count: report.updated,
        skipped_count: report.skipped,
        error_count: report.errors.length,
        report,
        completed_at: new Date().toISOString(),
      });
    } catch (error) {
      report.errors.push({ line: 0, error: error.message });
      if (jobId)
        await api()
          .update("item_import_jobs", jobId, {
            status: "failed",
            error_count: report.errors.length,
            report,
            completed_at: new Date().toISOString(),
          })
          .catch(() => {});
    }
    const node = document.getElementById("catalog-import-progress");
    if (node)
      node.innerHTML = `<div class="catalog-mini-kpis"><div><span>Créés</span><b>${report.created}</b></div><div><span>Mis à jour</span><b>${report.updated}</b></div><div><span>Ignorés</span><b>${report.skipped}</b></div><div><span>Erreurs</span><b>${report.errors.length}</b></div></div>${
        report.errors.length
          ? `<ul>${report.errors
              .slice(0, 30)
              .map(
                (entry) =>
                  `<li>${entry.line ? `Ligne ${entry.line} : ` : ""}${esc(entry.error)}</li>`,
              )
              .join("")}</ul>`
          : ""
      }`;
    const next = document.getElementById("catalog-import-next");
    if (next) {
      next.textContent = "Terminer";
      next.onclick = () => {
        closeModal();
        app().refresh();
      };
    }
    ui.busy = false;
  }
  function renderRoute(rawPath, currentState) {
    const path = String(rawPath || "").split("?")[0];
    if (path === "sales/catalog") {
      restore();
      renderList();
      return true;
    }
    if (path === "sales/catalog/new") {
      renderCreate();
      return true;
    }
    const match = path.match(/^sales\/items\/([0-9a-f-]+)$/i);
    if (match) {
      renderDetail(match[1]);
      return true;
    }
    return false;
  }
  Object.assign(global, {
    PilozCatalog: {
      ui,
      renderRoute,
      renderList,
      setSearch,
      setQuick,
      setFilter,
      clearFilters,
      toggleFilters,
      sort,
      page,
      setPageSize,
      setView,
      select,
      selectPage,
      clearSelection,
      openColumns,
      saveColumns,
      openSavedViews,
      saveView,
      applySavedView,
      closeModal,
      openEditor,
      syncItemType,
      applyCategoryDefaults,
      syncPrices,
      saveItem,
      setTab,
      openItemActions,
      duplicate,
      changeStatus,
      archive,
      remove,
      openTaxonomy,
      saveCategory,
      saveTag,
      saveCatalogSettings,
      saveCatalogUnits,
      openPrice,
      savePrice,
      openPriceList,
      savePriceList,
      openBulkPrice,
      previewBulkPrice,
      applyBulkPrice,
      bulkStatus,
      openSupplier,
      saveSupplier,
      makePrimarySupplier,
      openVariant,
      saveVariant,
      openVariantMatrix,
      generateVariantMatrix,
      openAttachment,
      saveAttachment,
      openAttachmentFile,
      openNote,
      saveNote,
      saveAccounting,
      addToDocument,
      addToPurchase,
      adjustStock,
      exportCsv,
      openImport,
      readImport,
      setImportMode,
      nextImport,
      runImport,
    },
  });
})(window);
