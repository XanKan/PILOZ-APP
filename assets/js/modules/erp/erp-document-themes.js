(function (global) {
  'use strict';
  const R = () => global.PilozDocumentThemeRenderer;
  const api = () => global.PilozERP || global.PilozApi;
  const app = () => global.PilozApp;
  const main = () => document.getElementById('main');
  const ui = { themeId: null, name: '', config: null, original: '', section: 'structure', dirty: false, saving: false, canManage: false, menu: null, modal: null, assets: [], links: [], footerLogos: [], zoom: .78 };
  const SECTION_META = [
    ['structure', '▦', 'Structure'], ['logo', '▧', 'Logo'], ['colors', '◉', 'Couleurs'], ['typography', 'T', 'Typographie'],
    ['table', '▤', 'Tableau'], ['decoration', '✦', 'Décoration'], ['footer', '▱', 'Pieds de page'],
    ['spacing', '↕', 'Espacement'], ['links', '↗', 'Lien'], ['assignments', '☑', 'Assignation']
  ];
  const e = value => R().esc(value);
  const state = () => app().getState();
  const notify = (message, type = 'success') => {
    if (global.PilozUI?.toast) global.PilozUI.toast(message, type);
    else if (global.PilozNotify) global.PilozNotify(message, type);
    else console[type === 'error' ? 'error' : 'info'](message);
  };
  const activeThemes = s => (s.data.templates || []).filter(theme => theme.status === 'active' && !theme.archived_at);
  const assignments = s => s.data.themeAssignments || [];
  const assignmentMap = s => new Map(assignments(s).map(row => [row.document_type, row.theme_id]));
  const userId = () => global.PilozRuntime?.session?.user_id || '';
  const currentPath = () => (location.hash || '#dashboard').slice(1);
  const button = (label, action, className = '') => `<button type="button" class="dt-button ${className}" onclick="${action}">${label}</button>`;
  const bool = value => value === true || value === 'true';
  const checked = value => bool(value) ? 'checked' : '';
  const selected = (actual, expected) => actual === expected ? 'selected' : '';
  const isAdmin = s => (s.data.members || []).some(member => member.user_id === userId() && (['owner', 'admin'].includes(member.role) || member.permissions?.manage_document_themes === true));
  function parseConfig(theme) { return R().normalize(theme?.thumbnail_config || {}); }
  function configText(config) { return JSON.stringify(R().normalize(config)); }
  function themeById(id) { return activeThemes(state()).find(theme => theme.id === id); }

  function renderRoute(path, s) {
    if (['templates', 'settings/templates', 'settings/appearance'].includes(path)) { renderAppearance(s); return true; }
    if (path === 'theme-editor') { renderEditor(); return true; }
    return false;
  }

  function thumbnail(theme, documentType = 'invoice') {
    return `<div class="dt-thumbnail">${R().render(parseConfig(theme), R().sample(documentType), { specimen: false, documentType })}</div>`;
  }

  function renderAppearance(s = state()) {
    closeModal();
    const themes = activeThemes(s), map = assignmentMap(s), canManage = isAdmin(s);
    main().innerHTML = `<div class="document-themes-page">
      <div class="dt-heading"><div><h1>Apparence</h1><p>Personnalisez l’apparence de vos documents commerciaux, puis choisissez le thème appliqué par défaut.</p></div>${button('En savoir plus⌄', 'PilozDocumentThemes.toggleHelp()')}</div>
      <section id="dt-help" class="dt-help"><button aria-label="Fermer" onclick="PilozDocumentThemes.dismissHelp()">×</button><strong>Modifiez l’apparence de vos documents</strong><span>Créez plusieurs thèmes sans modifier les documents déjà finalisés. L’aperçu utilise exactement les mêmes réglages que le PDF.</span><nav><button onclick="PilozDocumentThemes.showHelp('guide')">▧ Comment ça marche ?</button><button onclick="PilozDocumentThemes.showHelp('faq')">ⓘ FAQ facturation</button></nav></section>
      <div class="dt-card-grid">${themes.map(theme => { const isDefault=[...map.values()].includes(theme.id); return `<article class="dt-theme-card" data-theme-card="${theme.id}" onclick="PilozDocumentThemes.openEditor('${theme.id}')">${isDefault ? '<span class="dt-default-badge">Par défaut</span>' : ''}${thumbnail(theme)}<div class="dt-card-title"><h2 title="${e(theme.name)}">${e(theme.name)}</h2>${canManage ? `<div class="dt-card-actions"><button class="dt-button" aria-label="Actions" onclick="event.stopPropagation();PilozDocumentThemes.toggleMenu('${theme.id}')">•••</button>${ui.menu === theme.id ? renderCardMenu(theme, canManage) : ''}</div>` : ''}</div><button type="button" class="dt-button primary" onclick="event.stopPropagation();PilozDocumentThemes.openEditor('${theme.id}')">${canManage ? 'Modifier' : 'Consulter'}</button></article>`; }).join('')}
        ${canManage ? `<article class="dt-theme-card dt-create-card" onclick="PilozDocumentThemes.openCreateModal()"><div><span>+</span><h2>Nouveau thème</h2><p>Partir de zéro ou copier un thème existant.</p></div></article>` : ''}</div>
      <section class="dt-assignments"><div class="dt-assignments-head"><h2>Thème par défaut par type de document</h2><p>Le thème choisi sera appliqué automatiquement à chaque nouveau document. Les documents finalisés ne changent jamais.</p></div>
        ${R().TYPES.map(([type, label]) => `<label class="dt-assignment-row"><strong>${e(label)}</strong><select ${canManage ? '' : 'disabled'} onchange="PilozDocumentThemes.assign('${type}',this.value)">${themes.map(theme => `<option value="${theme.id}" ${selected(map.get(type), theme.id)}>${e(theme.name)}</option>`).join('')}</select></label>`).join('')}
      </section></div>`;
    const pref = (s.data.themePreferences || [])[0];
    if (pref?.help_dismissed) document.getElementById('dt-help')?.remove();
  }

  function renderCardMenu(theme, canManage) {
    if (!canManage) return '';
    return `<div class="dt-card-menu" onclick="event.stopPropagation()"><button onclick="PilozDocumentThemes.openEditor('${theme.id}')">Modifier</button><button onclick="PilozDocumentThemes.rename('${theme.id}')">Renommer</button><button onclick="PilozDocumentThemes.duplicate('${theme.id}')">Dupliquer</button><button onclick="PilozDocumentThemes.openAssignmentModal('${theme.id}')">Définir comme thème par défaut</button><button onclick="PilozDocumentThemes.viewAssignments('${theme.id}')">Voir les assignations</button><button onclick="PilozDocumentThemes.archive('${theme.id}')">Archiver</button><button class="danger" onclick="PilozDocumentThemes.remove('${theme.id}')">Supprimer</button></div>`;
  }
  function toggleMenu(id) { ui.menu = ui.menu === id ? null : id; renderAppearance(); }
  function toggleHelp() { const help = document.getElementById('dt-help'); if (help) help.hidden = !help.hidden; }
  function showHelp(topic) {
    const messages = {
      guide: 'Créez ou copiez un thème, personnalisez-le, puis assignez-le aux types de documents voulus. Les documents finalisés restent figés.',
      faq: 'Un changement de thème s’applique aux nouveaux documents et aux brouillons qui l’utilisent. Il ne modifie jamais un PDF déjà finalisé.'
    };
    notify(messages[topic] || messages.guide, 'success');
  }
  async function dismissHelp() {
    document.getElementById('dt-help')?.remove();
    try { await api().request('/rest/v1/document_theme_user_preferences?on_conflict=company_id,user_id', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }, body: api().serializeBody({ company_id: state().companyId, user_id: userId(), help_dismissed: true }) }); } catch {}
  }

  function openCreateModal() {
    const themes = activeThemes(state());
    document.body.insertAdjacentHTML('beforeend', `<div id="dt-modal" class="dt-modal-shade" role="dialog" aria-modal="true"><form class="dt-modal" onsubmit="event.preventDefault();PilozDocumentThemes.createFromModal()"><h2>Créer un nouveau thème</h2><label class="dt-modal-option"><input type="radio" name="source_mode" value="blank" checked onchange="PilozDocumentThemes.toggleCreateSource()"><span><strong>Thème vierge</strong><span>Partir d’un thème avec les valeurs par défaut</span></span></label><label class="dt-modal-option"><input type="radio" name="source_mode" value="existing" onchange="PilozDocumentThemes.toggleCreateSource()"><span><strong>Thème existant</strong><span>Partir d’une copie de l’un de vos thèmes</span><select name="source_theme_id" disabled>${themes.map(theme => `<option value="${theme.id}">${e(theme.name)}</option>`).join('')}</select></span></label><div class="dt-modal-actions">${button('Annuler', 'PilozDocumentThemes.closeModal()')}${button('Créer le thème', 'PilozDocumentThemes.createFromModal()', 'primary')}</div></form></div>`);
  }
  function toggleCreateSource() { const form = document.querySelector('#dt-modal form'); if (form) form.elements.source_theme_id.disabled = form.elements.source_mode.value !== 'existing'; }
  function closeModal() { document.getElementById('dt-modal')?.remove(); }
  function closeTransient() { closeModal(); ui.menu = null; }
  async function createFromModal() {
    const form = document.querySelector('#dt-modal form'); if (!form || ui.saving) return;
    const source = form.elements.source_mode.value === 'existing' ? form.elements.source_theme_id.value : null;
    ui.saving = true;
    try {
      const result = await api().rpc('create_document_theme', { target_company_id: state().companyId, target_source_theme_id: source || null });
      closeModal(); await app().refresh(); await openEditor(result.theme_id); notify('Thème créé avec succès.');
    } catch (error) { notify(error.message || 'Le thème n’a pas pu être créé.', 'error'); }
    finally { ui.saving = false; }
  }
  async function duplicate(id) { closeModal(); ui.menu = null; try { const result = await api().rpc('create_document_theme', { target_company_id: state().companyId, target_source_theme_id: id }); await app().refresh(); await openEditor(result.theme_id); notify('Le thème a été dupliqué.'); } catch (error) { notify(error.message, 'error'); } }
  function openAssignmentModal(id) {
    const theme=themeById(id); if(!theme)return;
    document.body.insertAdjacentHTML('beforeend', `<div id="dt-modal" class="dt-modal-shade" role="dialog" aria-modal="true"><form class="dt-modal" onsubmit="event.preventDefault();PilozDocumentThemes.assignFromModal('${id}')"><h2>Définir « ${e(theme.name)} » par défaut</h2><label class="dt-field"><span>Type de document</span><select name="document_type">${R().TYPES.map(([type,label])=>`<option value="${type}">${e(label)}</option>`).join('')}</select></label><p>Le thème remplacera uniquement l’assignation du type choisi. Les documents finalisés ne seront pas modifiés.</p><div class="dt-modal-actions">${button('Annuler','PilozDocumentThemes.closeModal()')}${button('Définir par défaut',`PilozDocumentThemes.assignFromModal('${id}')`,'primary')}</div></form></div>`);
  }
  async function assignFromModal(id){const form=document.querySelector('#dt-modal form'),type=form?.elements.document_type?.value;if(!type)return;closeModal();await assign(type,id);}
  async function viewAssignments(id){await openEditor(id);ui.section='assignments';renderEditor();}
  async function rename(id) { const theme = themeById(id), name = prompt('Nouveau nom du thème :', theme?.name || ''); if (!name?.trim()) return; try { await api().rpc('rename_document_theme', { target_theme_id: id, target_name: name.trim() }); await app().refresh(); renderAppearance(); notify('Le thème a été renommé.'); } catch (error) { notify(error.message, 'error'); } }
  async function archive(id) { if (!confirm('Archiver ce thème ? Il restera disponible dans l’historique mais ne pourra plus être attribué.')) return; try { await api().rpc('archive_document_theme', { target_theme_id: id }); await app().refresh(); renderAppearance(); notify('Thème archivé.'); } catch (error) { notify(readableError(error), 'error'); } }
  async function remove(id) { if (!confirm('Supprimer définitivement ce thème inutilisé ?')) return; try { await api().rpc('delete_document_theme', { target_theme_id: id }); await app().refresh(); renderAppearance(); notify('Thème supprimé.'); } catch (error) { notify(readableError(error), 'error'); } }
  async function assign(type, themeId) { try { await api().rpc('assign_document_theme', { target_theme_id: themeId, target_document_type: type }); await app().refresh(); renderAppearance(); notify('Thème par défaut mis à jour.'); } catch (error) { notify(error.message, 'error'); } }
  function readableError(error) { const text = String(error?.message || error || 'Action impossible.'); if (text.includes('theme_is_assigned')) return 'Ce thème est encore attribué à un type de document. Choisissez d’abord un autre thème par défaut.'; if (text.includes('theme_is_used')) return 'Ce thème est utilisé par un document et ne peut pas être supprimé. Vous pouvez l’archiver.'; return text; }

  async function openEditor(id) {
    const theme = themeById(id); if (!theme) return;
    ui.themeId = id; ui.name = theme.name; ui.section = 'structure'; ui.dirty = false; ui.canManage = isAdmin(state()); ui.assets = []; ui.links = []; ui.footerLogos = [];
    try {
      const [versions, assets, links, footerLogos] = await Promise.all([
        api().query('document_template_versions', `select=*&template_id=eq.${encodeURIComponent(id)}&order=version.desc&limit=1`),
        api().query('document_theme_assets', `select=*&theme_id=eq.${encodeURIComponent(id)}&order=created_at.desc`).catch(() => []),
        api().query('document_theme_links', `select=*&theme_id=eq.${encodeURIComponent(id)}&order=position`).catch(() => []),
        api().query('document_theme_footer_logos', `select=*&theme_id=eq.${encodeURIComponent(id)}&order=position`).catch(() => [])
      ]);
      ui.assets = assets; ui.links = links; ui.footerLogos = footerLogos;
      ui.config = R().normalize(versions[0]?.configuration_json || theme.thumbnail_config || {});
      ui.config.links = links.length ? links.map(link => ({ id: link.id, label: link.label, url: link.url, display_text: link.display_text, placement: link.placement })) : ui.config.links;
      ui.config.assignments = assignments(state()).filter(row => row.theme_id === id).map(row => row.document_type);
      await hydrateAssetUrls(); ui.original = configText(ui.config); location.hash = 'theme-editor'; renderEditor();
    } catch (error) { notify(error.message || 'Le thème ne peut pas être chargé.', 'error'); }
  }
  async function hydrateAssetUrls() {
    await Promise.all(ui.assets.map(async asset => { try { const signed = await api().signedUrl(asset.storage_bucket || 'company-assets', asset.storage_path, 3600); asset.signed_url = signed.signedURL || signed.signedUrl || ''; } catch { asset.signed_url = ''; } }));
    const logo = ui.assets.find(asset => asset.id === ui.config.logo.asset_id) || ui.assets.find(asset => asset.asset_type === 'logo');
    if (logo) { ui.config.logo.asset_id = logo.id; ui.config.logo.storage_path = logo.storage_path; ui.config.logo.signed_url = logo.signed_url; }
    const decoration = ui.assets.find(asset => asset.id === ui.config.decoration.asset_id);
    if (decoration) ui.config.decoration.signed_url = decoration.signed_url;
  }
  function previewData(documentType = 'invoice') {
    const data = R().sample(documentType);
    data.footer_logos = ui.footerLogos.filter(row => row.visible !== false && (!Array.isArray(row.document_types) || !row.document_types.length || row.document_types.includes(documentType) || (documentType !== 'quote' && row.document_types.includes('invoice')))).map(row => {
      const asset = ui.assets.find(item => item.id === row.asset_id);
      return { name: row.name, width: row.width, signed_url: asset?.signed_url || '' };
    });
    return data;
  }

  function renderEditor() {
    if (!ui.themeId || !ui.config) { location.hash = 'settings/appearance'; return; }
    const theme = themeById(ui.themeId), themes = activeThemes(state());
    main().innerHTML = `<div class="dt-editor ${ui.canManage ? '' : 'readonly'}"><aside class="dt-editor-nav"><div class="dt-editor-theme"><div class="dt-editor-thumb">${R().render(ui.config, previewData(), { specimen: false })}</div><select onchange="PilozDocumentThemes.switchTheme(this.value)">${themes.map(row => `<option value="${row.id}" ${selected(row.id, ui.themeId)}>${e(row.name)}</option>`).join('')}</select>${ui.canManage ? '<button onclick="PilozDocumentThemes.renameEditor()">✎ Renommer</button>' : '<small>Mode consultation</small>'}</div><h3>Personnalisation</h3>${SECTION_META.map(([key, icon, label]) => `<button class="dt-section-button ${ui.section === key ? 'active' : ''}" onclick="PilozDocumentThemes.setSection('${key}')"><b>${icon}</b><span>${label}</span></button>`).join('')}</aside>
      <section id="dt-editor-panel" class="dt-editor-panel">${ui.canManage ? renderPanel() : `<p class="dt-readonly-note">Vous pouvez consulter ce thème, mais votre rôle ne permet pas de modifier les paramètres globaux.</p><fieldset class="dt-readonly-fields" disabled>${renderPanel()}</fieldset>`}</section><main class="dt-preview-area"><div class="dt-preview-toolbar"><button class="dt-button" onclick="PilozDocumentThemes.changeZoom(-.05)">−</button><span class="dt-button">${Math.round(ui.zoom * 100)} %</span><button class="dt-button" onclick="PilozDocumentThemes.changeZoom(.05)">+</button></div><div class="dt-preview-paper" style="max-width:${740 * ui.zoom}px">${R().render(ui.config, previewData(), { specimen: true })}</div></main>
      <footer class="dt-editor-footer"><div><button class="dt-button" onclick="PilozDocumentThemes.requestClose()">← Retour</button>${ui.dirty ? '<span class="dt-dirty"> Modifications non enregistrées</span>' : ''}</div>${ui.canManage ? `<button class="dt-button primary save" ${ui.saving ? 'disabled' : ''} onclick="PilozDocumentThemes.save()">${ui.saving ? 'Enregistrement…' : 'Enregistrer'}</button>` : '<span>Consultation uniquement</span>'}</footer></div><button class="dt-editor-close" aria-label="Fermer" onclick="PilozDocumentThemes.requestClose()">×</button>`;
  }
  function setSection(section) { ui.section = section; renderEditor(); }
  function changeZoom(delta) { ui.zoom = Math.max(.5, Math.min(1.05, ui.zoom + delta)); renderEditor(); }
  function dirty() { ui.config = R().normalize(ui.config); ui.dirty = configText(ui.config) !== ui.original; renderEditor(); }
  function set(path, value, valueType = 'string') {
    const keys = path.split('.'); let target = ui.config; keys.slice(0, -1).forEach(key => target = target[key]);
    if (valueType === 'boolean') value = bool(value); else if (valueType === 'number') value = Number(value);
    target[keys.at(-1)] = value;
    if (path === 'spacing.top' && ui.config.spacing.link_vertical) ui.config.spacing.bottom = value;
    if (path === 'spacing.bottom' && ui.config.spacing.link_vertical) ui.config.spacing.top = value;
    if (path === 'spacing.left' && ui.config.spacing.link_horizontal) ui.config.spacing.right = value;
    if (path === 'spacing.right' && ui.config.spacing.link_horizontal) ui.config.spacing.left = value;
    dirty();
  }
  function setColor(key, value) {
    if (!/^#[0-9a-f]{6}$/i.test(value)) { notify('Saisissez une couleur hexadécimale valide, par exemple #13294B.', 'error'); return; }
    set(`colors.${key}`, value.toUpperCase());
    if (['primary','background','text'].includes(key) && contrast(ui.config.colors.text, ui.config.colors.background) < 4.5) notify('Attention : le contraste du texte est faible pour l’impression.', 'error');
  }
  function contrast(left, right) {
    const luminance = hex => { const channels = hex.slice(1).match(/../g).map(value => parseInt(value,16)/255).map(value => value<=.03928?value/12.92:((value+.055)/1.055)**2.4); return .2126*channels[0]+.7152*channels[1]+.0722*channels[2]; };
    const [a,b]=[luminance(left),luminance(right)].sort((x,y)=>y-x); return (a+.05)/(b+.05);
  }
  function applyPalette(index) { const palette = R().PALETTES[index]; if (!palette) return; [ui.config.colors.primary, ui.config.colors.secondary, ui.config.colors.background, ui.config.colors.text] = palette; dirty(); }
  function renameEditor() { const name = prompt('Nouveau nom du thème :', ui.name); if (name?.trim() && name.trim() !== ui.name) { ui.name = name.trim(); ui.dirty = true; renderEditor(); } }
  async function switchTheme(id) { if (id === ui.themeId) return; if (ui.dirty && !confirm('Abandonner les modifications non enregistrées ?')) { renderEditor(); return; } await openEditor(id); }
  function requestClose() { if (ui.dirty && !confirm('Vous avez des modifications non enregistrées. Les abandonner ?')) return; ui.themeId = null; ui.config = null; location.hash = 'settings/appearance'; }

  function renderPanel() {
    const panel = ({ title, lead, body }) => `<h2>${title}</h2><p class="dt-panel-lead">${lead}</p>${body}`;
    const c = ui.config;
    if (ui.section === 'structure') return panel({ title: 'Structure', lead: 'Choisissez la mise en page de vos documents.', body: `<div class="dt-choice-grid">${R().STRUCTURES.map(([key, label]) => `<button class="dt-choice ${c.structure.key === key ? 'active' : ''}" onclick="PilozDocumentThemes.set('structure.key','${key}')"><div class="dt-choice-preview">${R().render({ ...c, structure: { key } }, R().sample(), { specimen: false })}</div><span>${e(label)}</span></button>`).join('')}</div>` });
    if (ui.section === 'logo') return panel({ title: 'Logo', lead: 'Importez un logo privé et choisissez sa taille dans le document.', body: `<label class="dt-upload">▧<strong>Cliquez pour importer</strong><span>PNG, JPG, WEBP ou SVG — 5 Mo maximum</span><input type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml" onchange="PilozDocumentThemes.uploadAsset(this.files[0],'logo')"></label><div class="dt-assets"><button class="dt-asset ${!c.logo.enabled ? 'active' : ''}" onclick="PilozDocumentThemes.clearLogo()">Aucun logo</button>${ui.assets.filter(asset => asset.asset_type === 'logo').map(asset => `<button class="dt-asset ${c.logo.asset_id === asset.id ? 'active' : ''}" onclick="PilozDocumentThemes.chooseLogo('${asset.id}')"><img src="${e(asset.signed_url)}" alt="${e(asset.name)}"></button>`).join('')}</div><label class="dt-toggle-row"><span>Afficher le logo</span><input class="dt-toggle" type="checkbox" ${checked(c.logo.enabled)} onchange="PilozDocumentThemes.set('logo.enabled',this.checked,'boolean')"></label><label class="dt-field"><span>Taille du logo : ${Number(c.logo.width)} px</span><input type="range" min="48" max="260" value="${Number(c.logo.width)}" oninput="PilozDocumentThemes.set('logo.width',this.value,'number')"></label><label class="dt-field"><span>Alignement</span><select onchange="PilozDocumentThemes.set('logo.alignment',this.value)"><option value="left" ${selected(c.logo.alignment,'left')}>Gauche</option><option value="center" ${selected(c.logo.alignment,'center')}>Centre</option><option value="right" ${selected(c.logo.alignment,'right')}>Droite</option></select></label>${toggle('Préserver les proportions','logo.preserve_ratio',c.logo.preserve_ratio)}` });
    if (ui.section === 'colors') return panel({ title: 'Couleurs', lead: 'Personnalisez les couleurs principales de vos documents.', body: `<div class="dt-palettes">${R().PALETTES.map((palette, index) => `<button class="dt-palette" onclick="PilozDocumentThemes.applyPalette(${index})">${palette.slice(0, 3).map(value => `<span style="background:${value}"></span>`).join('')}</button>`).join('')}</div><div class="dt-color-grid">${[['primary','Principale'],['secondary','Secondaire'],['background','Arrière-plan'],['text','Textes'],['muted','Texte secondaire'],['border','Bordures']].map(([key, label]) => `<label class="dt-field"><span>${label}</span><span class="dt-color-field"><input type="color" value="${c.colors[key]}" oninput="PilozDocumentThemes.setColor('${key}',this.value)"><input value="${c.colors[key]}" onchange="PilozDocumentThemes.setColor('${key}',this.value)"></span></label>`).join('')}</div>` });
    if (ui.section === 'typography') return panel({ title: 'Typographie', lead: 'Choisissez les polices et les tailles du document.', body: ['title','content','table'].map(key => `<section><label class="dt-field"><span>${{ title:'Titre',content:'Contenu',table:'Tableau' }[key]}</span><select onchange="PilozDocumentThemes.set('typography.${key}.family',this.value)">${R().FONTS.map(font => `<option ${selected(c.typography[key].family, font)}>${font}</option>`).join('')}</select></label><div class="dt-segment">${[['small','Petit'],['normal','Normal'],['large','Grand']].map(([size,label]) => `<button class="${c.typography[key].size === size ? 'active' : ''}" onclick="PilozDocumentThemes.set('typography.${key}.size','${size}')">${label}</button>`).join('')}</div></section><br>`).join('') });
    if (ui.section === 'table') return panel({ title: 'Tableau', lead: 'Personnalisez le tableau et les colonnes visibles.', body: `${toggle('Lignes alternées','table.striped',c.table.striped)}${toggle('Bordures visibles','table.borders',c.table.borders)}${toggle('En-tête colorée','table.colored_header',c.table.colored_header)}<label class="dt-field"><span>Arrondi : ${Number(c.table.radius)} px</span><input type="range" min="0" max="14" value="${Number(c.table.radius)}" oninput="PilozDocumentThemes.set('table.radius',this.value,'number')"></label><h3>Colonnes</h3><div>${c.table.columns.map(column => `<div class="dt-column-row" draggable="true" ondragstart="PilozDocumentThemes.dragColumn('${column.key}')" ondragover="event.preventDefault()" ondrop="PilozDocumentThemes.dropColumn('${column.key}')"><span class="handle">⠿</span><span>${e(column.label)}</span><input class="dt-toggle" type="checkbox" ${checked(column.visible)} ${column.locked ? 'disabled' : ''} onchange="PilozDocumentThemes.toggleColumn('${column.key}',this.checked)"></div>`).join('')}</div>` });
    if (ui.section === 'decoration') return panel({ title: 'Décoration', lead: 'Ajoutez un fond graphique discret au document.', body: `<div class="dt-decoration-grid">${R().DECORATIONS.map(kind => `<button title="${kind}" class="dt-decoration ${kind} ${c.decoration.kind === kind ? 'active' : ''}" onclick="PilozDocumentThemes.set('decoration.kind','${kind}')"></button>`).join('')}</div><label class="dt-field"><span>Opacité : ${Math.round(Number(c.decoration.opacity) * 100)} %</span><input type="range" min="0" max="0.35" step="0.01" value="${Number(c.decoration.opacity)}" oninput="PilozDocumentThemes.set('decoration.opacity',this.value,'number')"></label>${c.decoration.kind === 'custom' ? '<label class="dt-upload">Importer un fond personnalisé<input type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml" onchange="PilozDocumentThemes.uploadAsset(this.files[0],\'decoration\')"></label>' : ''}` });
    if (ui.section === 'footer') return panel({ title: 'Pieds de page', lead: 'Valorisez votre expertise avec vos certifications et labels.', body: `${toggle('Afficher les mentions légales','footer.show_legal',c.footer.show_legal)}${toggle('Afficher les coordonnées','footer.show_contact',c.footer.show_contact)}${toggle('Afficher les coordonnées bancaires','footer.show_bank_details',c.footer.show_bank_details)}${toggle('Afficher le numéro de page','footer.show_page_number',c.footer.show_page_number)}${toggle('Afficher « Généré avec Piloz »','footer.show_piloz_brand',c.footer.show_piloz_brand)}<label class="dt-field"><span>Texte libre</span><textarea maxlength="600" onchange="PilozDocumentThemes.set('footer.free_text',this.value)">${e(c.footer.free_text)}</textarea></label><h3>Logos de pieds de page</h3><div class="dt-footer-logo-list">${ui.footerLogos.map(row => { const asset=ui.assets.find(item=>item.id===row.asset_id),types=Array.isArray(row.document_types)?row.document_types:[]; return `<article class="dt-footer-logo-row"><img src="${e(asset?.signed_url||'')}" alt="${e(row.name)}"><div><input aria-label="Nom du logo" value="${e(row.name)}" onchange="PilozDocumentThemes.setFooterLogo('${row.id}','name',this.value)"><label>Taille : ${Number(row.width||64)} px<input type="range" min="24" max="180" value="${Number(row.width||64)}" onchange="PilozDocumentThemes.setFooterLogo('${row.id}','width',this.value,'number')"></label><label>Types de documents<select multiple size="3" onchange="PilozDocumentThemes.setFooterLogoTypes('${row.id}',[...this.selectedOptions].map(option=>option.value))"><option value="" ${types.length?'':'selected'}>Tous</option>${R().TYPES.map(([type,label])=>`<option value="${type}" ${types.includes(type)?'selected':''}>${e(label)}</option>`).join('')}</select></label></div><div class="dt-footer-logo-actions"><label title="Afficher"><input type="checkbox" ${checked(row.visible!==false)} onchange="PilozDocumentThemes.setFooterLogo('${row.id}','visible',this.checked,'boolean')"> Visible</label><button title="Déplacer à gauche" onclick="PilozDocumentThemes.moveFooterLogo('${row.id}',-1)">←</button><button title="Déplacer à droite" onclick="PilozDocumentThemes.moveFooterLogo('${row.id}',1)">→</button><button title="Supprimer" onclick="PilozDocumentThemes.removeFooterLogo('${row.id}')">×</button></div></article>`; }).join('')}</div><label class="dt-upload">Ajouter un logo de certification<input type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml" onchange="PilozDocumentThemes.uploadAsset(this.files[0],'footer_logo')"></label>` });
    if (ui.section === 'spacing') return panel({ title: 'Espacement', lead: 'Réglez les marges du document en pixels.', body: `<div class="dt-margin-grid">${[['top','Haut'],['bottom','Bas'],['left','Gauche'],['right','Droite']].map(([key,label]) => `<label class="dt-field"><span>${label}</span><input type="number" min="12" max="120" value="${Number(c.spacing[key])}" onchange="PilozDocumentThemes.set('spacing.${key}',this.value,'number')"></label>`).join('')}</div>${toggle('Lier les marges verticales','spacing.link_vertical',c.spacing.link_vertical)}${toggle('Lier les marges horizontales','spacing.link_horizontal',c.spacing.link_horizontal)}${button('Réinitialiser les marges','PilozDocumentThemes.resetSpacing()')}` });
    if (ui.section === 'links') return panel({ title: 'Lien', lead: 'Ajoutez des liens HTTPS cliquables dans vos documents.', body: `<div>${c.links.map((link,index) => `<div class="dt-link-row"><div class="row"><input placeholder="Libellé" value="${e(link.label || '')}" onchange="PilozDocumentThemes.setLink(${index},'label',this.value)"><input type="url" placeholder="https://…" value="${e(link.url || '')}" onchange="PilozDocumentThemes.setLink(${index},'url',this.value)"><button class="dt-button danger" onclick="PilozDocumentThemes.removeLink(${index})">×</button></div></div>`).join('')}</div>${button('+ Ajouter un lien','PilozDocumentThemes.addLink()')}` });
    return panel({ title: 'Assignation', lead: 'Choisissez ce thème comme apparence par défaut pour vos documents.', body: `${R().TYPES.map(([type,label]) => `<label class="dt-assignment-choice"><input type="checkbox" ${checked(c.assignments.includes(type))} onchange="PilozDocumentThemes.toggleAssignment('${type}',this.checked)"><span><strong>${e(label)}</strong><small>Thème actuel : ${e(themeById(assignmentMap(state()).get(type))?.name || 'Non défini')}</small></span></label>`).join('')}<p class="dt-help">L’assignation concerne les nouveaux documents. Les documents finalisés gardent leur version historique.</p>` });
  }
  function toggle(label, path, value) { return `<label class="dt-toggle-row"><span>${label}</span><input class="dt-toggle" type="checkbox" ${checked(value)} onchange="PilozDocumentThemes.set('${path}',this.checked,'boolean')"></label>`; }
  let draggedColumn = null;
  function dragColumn(key) { draggedColumn = key; }
  function dropColumn(targetKey) { if (!draggedColumn || draggedColumn === targetKey) return; const rows = ui.config.table.columns, from = rows.findIndex(row => row.key === draggedColumn), to = rows.findIndex(row => row.key === targetKey), [row] = rows.splice(from, 1); rows.splice(to, 0, row); rows.forEach((column, index) => column.position = index + 1); draggedColumn = null; dirty(); }
  function toggleColumn(key, visible) { const column = ui.config.table.columns.find(row => row.key === key); if (column && !column.locked) { column.visible = visible; dirty(); } }
  function setLink(index, key, value) { if (!ui.config.links[index]) return; ui.config.links[index][key] = value; ui.dirty = true; renderEditor(); }
  function addLink() { ui.config.links.push({ label: 'Mon site', url: 'https://piloz.fr', placement: 'footer' }); ui.dirty = true; renderEditor(); }
  function removeLink(index) { ui.config.links.splice(index, 1); dirty(); }
  function toggleAssignment(type, enabled) { const list = new Set(ui.config.assignments); enabled ? list.add(type) : list.delete(type); ui.config.assignments = [...list]; dirty(); }

  async function prepareThemeImage(source) {
    let file = source;
    if (source.type === 'image/svg+xml') {
      const documentNode = new DOMParser().parseFromString(await source.text(), 'image/svg+xml');
      if (documentNode.querySelector('parsererror')) throw new Error('Le fichier SVG est invalide.');
      documentNode.querySelectorAll('script,foreignObject,iframe,object,embed').forEach(node => node.remove());
      documentNode.querySelectorAll('*').forEach(node => [...node.attributes].forEach(attribute => {
        const name = attribute.name.toLowerCase(), value = attribute.value.trim();
        if (name.startsWith('on') || /^(javascript:|https?:|data:)/i.test(value) || /url\s*\(/i.test(value)) node.removeAttribute(attribute.name);
      }));
      file = new File([new XMLSerializer().serializeToString(documentNode)], source.name, { type: source.type });
    }
    if (['image/png','image/jpeg'].includes(file.type)) return file;
    return new Promise((resolve, reject) => {
      const objectUrl = URL.createObjectURL(file), image = new Image();
      image.onload = () => {
        try {
          const maxSide = 2400, scale = Math.min(1, maxSide / Math.max(image.naturalWidth, image.naturalHeight)), canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(image.naturalWidth * scale)); canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
          canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
          canvas.toBlob(blob => { URL.revokeObjectURL(objectUrl); blob ? resolve(new File([blob], source.name.replace(/\.[^.]+$/, '')+'.png', { type: 'image/png' })) : reject(new Error('Conversion de l’image impossible.')); }, 'image/png');
        } catch (error) { URL.revokeObjectURL(objectUrl); reject(error); }
      };
      image.onerror = () => { URL.revokeObjectURL(objectUrl); reject(new Error('L’image ne peut pas être lue.')); };
      image.src = objectUrl;
    });
  }

  async function uploadAsset(file, assetType) {
    if (!file) return;
    const allowed = ['image/png','image/jpeg','image/webp','image/svg+xml'];
    if (!allowed.includes(file.type) || file.size > 5 * 1024 * 1024) { notify('Utilisez un fichier PNG, JPG, WEBP ou SVG de 5 Mo maximum.', 'error'); return; }
    try {
      file = await prepareThemeImage(file);
      if (file.size > 5 * 1024 * 1024) throw new Error('L’image convertie dépasse 5 Mo.');
      const ext = file.type === 'image/jpeg' ? 'jpg' : 'png', path = `${state().companyId}/themes/${ui.themeId}/${crypto.randomUUID()}.${ext}`;
      await api().upload('company-assets', path, file);
      const inserted = await api().insert('document_theme_assets', { company_id: state().companyId, theme_id: ui.themeId, asset_type: assetType, name: file.name, storage_bucket: 'company-assets', storage_path: path, mime_type: file.type, size_bytes: file.size, created_by: userId() });
      const asset = inserted[0], signed = await api().signedUrl('company-assets', path, 3600); asset.signed_url = signed.signedURL || signed.signedUrl || ''; ui.assets.unshift(asset);
      if (assetType === 'logo') chooseLogo(asset.id);
      else if (assetType === 'footer_logo') { const rows=await api().insert('document_theme_footer_logos',{company_id:state().companyId,theme_id:ui.themeId,asset_id:asset.id,name:file.name,position:ui.footerLogos.length+1,width:64,created_by:userId()});ui.footerLogos.push(rows[0]);ui.config.footer.logo_ids=ui.footerLogos.map(row=>row.id);dirty(); }
      else { ui.config.decoration.asset_id = asset.id; ui.config.decoration.signed_url = asset.signed_url; dirty(); }
      notify('Image importée.');
    } catch (error) { notify(error.message || 'L’image n’a pas pu être importée.', 'error'); }
  }
  function chooseLogo(id) { const asset = ui.assets.find(row => row.id === id); if (!asset) return; Object.assign(ui.config.logo, { enabled: true, asset_id: id, storage_path: asset.storage_path, signed_url: asset.signed_url }); dirty(); }
  function clearLogo() { Object.assign(ui.config.logo,{enabled:false,asset_id:null,storage_path:null,signed_url:null});dirty(); }
  function resetSpacing(){ui.config.spacing={...R().defaults().spacing};dirty();}
  function setFooterLogo(id,key,value,valueType='string'){const row=ui.footerLogos.find(item=>item.id===id);if(!row)return;if(valueType==='number')value=Math.max(24,Math.min(180,Number(value)||64));else if(valueType==='boolean')value=bool(value);row[key]=value;ui.dirty=true;renderEditor();}
  function setFooterLogoTypes(id,types){const row=ui.footerLogos.find(item=>item.id===id);if(!row)return;row.document_types=(types||[]).filter(Boolean);ui.dirty=true;renderEditor();}
  async function removeFooterLogo(id){try{await api().remove('document_theme_footer_logos',id);ui.footerLogos=ui.footerLogos.filter(row=>row.id!==id);ui.config.footer.logo_ids=ui.footerLogos.map(row=>row.id);dirty();}catch(error){notify(error.message,'error');}}
  async function moveFooterLogo(id,delta){const from=ui.footerLogos.findIndex(row=>row.id===id),to=Math.max(0,Math.min(ui.footerLogos.length-1,from+delta));if(from<0||from===to)return;const [row]=ui.footerLogos.splice(from,1);ui.footerLogos.splice(to,0,row);try{for(let index=0;index<ui.footerLogos.length;index++){ui.footerLogos[index].position=index+1;await api().update('document_theme_footer_logos',ui.footerLogos[index].id,{position:index+1});}ui.config.footer.logo_ids=ui.footerLogos.map(item=>item.id);dirty();}catch(error){notify(error.message,'error');}}

  async function save() {
    if (ui.saving || !ui.dirty) return;
    const invalidLink = ui.config.links.find(link => !R().safeUrl(link.url));
    if (invalidLink) { notify('Chaque lien doit commencer par https:// ou http://.', 'error'); ui.section = 'links'; renderEditor(); return; }
    ui.saving = true; renderEditor();
    try {
      const persistedConfig = R().normalize(ui.config);
      delete persistedConfig.logo.signed_url; delete persistedConfig.decoration.signed_url;
      const result = await api().rpc('save_document_theme', { target_theme_id: ui.themeId, target_name: ui.name, target_configuration: persistedConfig, target_assignments: ui.config.assignments });
      await persistLinks(); await persistFooterLogos(); await app().refresh(); const theme = themeById(ui.themeId); if (theme) theme.thumbnail_config = R().normalize(ui.config);
      ui.original = configText(ui.config); ui.dirty = false; notify(`Thème enregistré — version ${result.version}.`); renderEditor();
    } catch (error) { notify(readableError(error), 'error'); }
    finally { ui.saving = false; renderEditor(); }
  }
  async function persistLinks() {
    const existing = ui.links || [], keep = new Set(ui.config.links.map(link => link.id).filter(Boolean));
    for (const row of existing.filter(link => !keep.has(link.id))) await api().remove('document_theme_links', row.id);
    for (let index = 0; index < ui.config.links.length; index++) {
      const link = ui.config.links[index], payload = { company_id: state().companyId, theme_id: ui.themeId, label: link.label || link.url, url: link.url, display_text: link.display_text || null, placement: link.placement || 'footer', position: index + 1 };
      if (link.id) await api().update('document_theme_links', link.id, payload); else { const inserted = await api().insert('document_theme_links', { ...payload, created_by: userId() }); link.id = inserted[0]?.id; }
    }
    ui.links = ui.config.links.map(link => ({ ...link }));
  }
  async function persistFooterLogos(){for(let index=0;index<ui.footerLogos.length;index++){const row=ui.footerLogos[index];row.position=index+1;await api().update('document_theme_footer_logos',row.id,{name:String(row.name||'Logo'),position:row.position,width:Number(row.width||64),visible:row.visible!==false,document_types:Array.isArray(row.document_types)?row.document_types:[]});}}

  function compatibleThemes(s, documentType) {
    const family = documentType === 'proforma_invoice' ? 'invoice' : documentType;
    return activeThemes(s).filter(theme => {
      const types = Array.isArray(theme.supported_document_types) ? theme.supported_document_types : [theme.document_type];
      return types.includes(family) || (family !== 'quote' && types.includes('invoice'));
    });
  }
  function resolveTheme(s, documentType, clientId, explicitId) {
    if (explicitId && compatibleThemes(s, documentType).some(theme => theme.id === explicitId)) return explicitId;
    const preference = (s.data.clientPreferences || []).find(row => row.client_id === clientId);
    const clientTemplate = documentType === 'quote' ? preference?.quote_template_id : preference?.invoice_template_id;
    if (clientTemplate && compatibleThemes(s, documentType).some(theme => theme.id === clientTemplate)) return clientTemplate;
    const mapped = assignmentMap(s).get(documentType) || (documentType !== 'quote' ? assignmentMap(s).get('invoice') : null);
    if (mapped) return mapped;
    const docs = s.data.docSettings?.[0] || {}, legacy = documentType === 'quote' ? docs.default_quote_template_id : docs.default_invoice_template_id;
    return legacy || compatibleThemes(s, documentType)[0]?.id || null;
  }

  function enhanceDocumentThemeSelector() {
    const s = state(), draft = s?.draft, box = document.querySelector('[data-document-metadata]');
    if (!draft || !box || box.dataset.themeEnhanced === 'true') return;
    const label = [...box.querySelectorAll('label')].find(node => /Mod.le de document/i.test(node.textContent));
    const select = label?.querySelector('select'); if (!select) return;
    box.dataset.themeEnhanced = 'true';
    label.childNodes[0].textContent = 'Thème du document';
    const themes = compatibleThemes(s, draft.document_type);
    select.innerHTML = `<option value="">Thème par défaut</option>${themes.map(theme => `<option value="${theme.id}" ${draft.template_id === theme.id ? 'selected' : ''}>${e(theme.name)}</option>`).join('')}`;
    select.onchange = () => { draft.template_id = select.value || resolveTheme(s, draft.document_type, draft.client_id, null); draft.theme_id = draft.template_id; };
  }

  global.PilozDocumentThemes = { renderRoute, renderAppearance, toggleMenu, toggleHelp, showHelp, dismissHelp, openCreateModal, toggleCreateSource, closeModal, createFromModal, duplicate, rename, archive, remove, assign, openAssignmentModal, assignFromModal, viewAssignments, openEditor, renderEditor, setSection, changeZoom, set, setColor, applyPalette, renameEditor, switchTheme, requestClose, dragColumn, dropColumn, toggleColumn, setLink, addLink, removeLink, toggleAssignment, uploadAsset, chooseLogo, clearLogo, resetSpacing, setFooterLogo, setFooterLogoTypes, removeFooterLogo, moveFooterLogo, save, compatibleThemes, resolveTheme };
  new MutationObserver(() => enhanceDocumentThemeSelector()).observe(document.documentElement, { childList: true, subtree: true });
})(window);
