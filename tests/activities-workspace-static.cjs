const fs = require("fs");
const path = require("path");
const assert = require("assert");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const migration = read(
  "supabase/migrations/202607310118_activities_workspace_completion.sql",
);
const security = read(
  "supabase/migrations/202607310119_activities_workspace_security_api.sql",
);
const knowledge = read(
  "supabase/migrations/202607310120_activities_knowledge_base.sql",
);
const scale = read(
  "supabase/migrations/202607310121_activities_enterprise_scale.sql",
);
const script = read("assets/js/modules/erp/erp-activities-workspace.js");
const css = read("assets/css/activities-workspace.css");
const index = read("index.html");
const crm = read("assets/js/modules/erp/erp-crm-rework.js");
const erpApp = read("assets/js/modules/erp/erp-app.js");

const checks = [];
function check(name, condition) {
  assert.ok(condition, name);
  checks.push(name);
}
function has(source, value) {
  if (source.includes(value)) return true;
  const normalized = (input) => input.replace(/\s+/g, "").replace(/["']/g, '"');
  return normalized(source).includes(normalized(value));
}

check(
  "migrations additives",
  !/(drop\s+table|truncate\s+table)/i.test(migration + security + scale),
);
check(
  "types configurables",
  has(migration, "create table if not exists public.activity_types"),
);
check(
  "résultats configurables",
  has(migration, "create table if not exists public.activity_outcomes"),
);
check(
  "rappels persistants",
  has(migration, "create table if not exists public.activity_reminders"),
);
check(
  "checklist persistante",
  has(migration, "create table if not exists public.activity_checklist_items"),
);
check(
  "pièces jointes persistantes",
  has(migration, "create table if not exists public.activity_attachments"),
);
check(
  "événements append-only",
  has(migration, "create table if not exists public.activity_events") &&
    has(
      security,
      "revoke insert,update,delete on public.activity_events from authenticated",
    ),
);
check(
  "filtres sauvegardés",
  has(migration, "create table if not exists public.activity_saved_filters"),
);
check(
  "liens de synchronisation",
  has(migration, "create table if not exists public.activity_sync_links"),
);
check(
  "provisionnement nouvelles entreprises",
  has(migration, "companies_provision_activity_types") &&
    has(migration, "seed_company_activity_types(new.id)"),
);
check(
  "migration activités existantes",
  has(migration, "activities_validate_workspace") &&
    has(migration, "activity_type_id"),
);
check(
  "suppression physique bloquée",
  has(migration, "activities_prevent_physical_delete"),
);
check(
  "index métier",
  has(migration, "activities_workspace_range_idx") &&
    has(migration, "activities_workspace_owner_idx") &&
    has(migration, "activity_events_activity_idx"),
);

check(
  "route activities autonome",
  has(script, "__activitiesWorkspaceRouteInstalled") &&
    has(script, "function activitiesWorkspaceRoute"),
);
check(
  "module sans abandon silencieux",
  !has(script, "if(!crm||!api()||!app())return"),
);
check("alias activities direct", has(erpApp, "activities:'activities'"));

for (const rpc of [
  "get_activity_workspace_v3",
  "get_activity_detail",
  "save_activity_workspace",
  "complete_activity_workspace",
  "transition_activity_workspace",
  "duplicate_activity_workspace",
  "register_activity_attachment",
  "save_activity_type",
  "save_activity_saved_filter",
  "delete_activity_saved_filter",
  "dispatch_due_activity_reminders",
]) {
  check(`RPC ${rpc}`, has(security, `function public.${rpc}`));
}
check("contexte entreprise serveur", has(security, "public._crm_context()"));
check(
  "visibilité centralisée",
  has(security, "function public.activity_is_visible"),
);
check(
  "écriture centralisée",
  has(security, "function public.activity_is_writable"),
);
check(
  "RLS confidentialité restrictive",
  has(
    security,
    "activities_confidentiality_select on public.activities as restrictive",
  ),
);
check(
  "RLS relations",
  has(
    security,
    "'activity_reminders','activity_checklist_items','activity_attachments','activity_events','activity_sync_links'",
  ),
);
check(
  "RLS stockage",
  has(security, "activity_attachments_storage_read") &&
    has(security, "activity_attachments_storage_insert"),
);
check(
  "isolation multi-entreprises",
  has(security, "activity.company_id=context_row.company_id"),
);
check(
  "portées personnel équipe entreprise",
  has(security, "array['own','team','company']") &&
    has(security, "public._crm_has_scope"),
);
check(
  "confidentialité privée équipe entreprise",
  has(security, "confidentiality in('standard','company','team','private')") &&
    has(security, "activity.confidentiality<>'private'"),
);
check("contrôle relations serveur", has(security, "activity_relation_exists"));
check(
  "journalisation des opérations",
  has(migration, "activities_append_event"),
);

check(
  "route activités dédiée",
  has(
    crm,
    "current==='crm/activities'||current==='activities'||route==='activities'",
  ),
);
check("asset JS chargé", has(index, "erp-activities-workspace.js"));
check("asset CSS chargé", has(index, "activities-workspace.css"));
check(
  "vues principales",
  [
    /["']list["']\s*,\s*["']Liste["']/,
    /["']agenda["']\s*,\s*["']Agenda["']/,
    /["']timeline["']\s*,\s*["']Chronologie["']/,
    /["']mine["']\s*,\s*["']Mes activités["']/,
    /["']team["']\s*,\s*["']Équipe["']/,
  ].every((pattern) => pattern.test(script)),
);
check(
  "agenda jour semaine mois",
  [
    /ui\.calendarMode\s*===\s*["']day["']/,
    /ui\.calendarMode\s*===\s*["']month["']/,
    /ui\.calendarMode\s*===\s*["']week["']/,
  ].every((pattern) => pattern.test(script)),
);
check(
  "filtres rapides",
  [
    /["']today["']\s*,\s*["']Aujourd’hui["']/,
    /["']overdue["']\s*,\s*["']En retard["']/,
    /["']completed["']\s*,\s*["']Terminées["']/,
  ].every((pattern) => pattern.test(script)),
);
check(
  "pagination serveur",
  has(script, "target_page:ui.page") &&
    has(script, "target_page_size:ui.pageSize"),
);
check(
  "pagination grand volume",
  has(script, "[25, 50, 100, 200]") && has(scale, "least(200"),
);
check(
  "préférences utilisateur persistantes",
  has(
    scale,
    "create table if not exists public.activity_workspace_preferences",
  ) && has(script, "save_activity_workspace_preferences"),
);
check(
  "recherche relationnelle serveur",
  has(scale, "function public.search_activity_relations") &&
    has(script, "search_activity_relations"),
);
check(
  "actions groupées atomiques",
  has(scale, "function public.bulk_transition_activities_workspace") &&
    has(script, "bulk_transition_activities_workspace"),
);
check(
  "agrégation serveur unique",
  has(scale, "with scope_rows as materialized") &&
    has(scale, ", counters as ("),
);
check(
  "index grand volume",
  has(scale, "activities_workspace_company_date_idx") &&
    has(scale, "activities_workspace_company_owner_date_idx"),
);
check("recherche temporisée", has(script, "searchTimer"));
check(
  "création et modification",
  has(script, "save_activity_workspace") &&
    has(script, "id?'Modifier l’activité':'Nouvelle activité'"),
);
check(
  "relations CRM et documents",
  has(script, "entity_type:'opportunity'") &&
    has(script, "relationType(document)") &&
    has(script, "entity_type:'supplier'"),
);
check(
  "participants checklist rappel",
  has(script, "participants,checklist,reminders"),
);
check(
  "clôture et prochaine action",
  has(script, "complete_activity_workspace") &&
    has(script, "target_next_payload:next"),
);
check(
  "report annulation archivage duplication",
  has(script, "target_action:action") &&
    has(script, "duplicate_activity_workspace"),
);
check(
  "upload limité et signé",
  has(script, "file.size>15728640") &&
    has(script, "api().signedUrl('activity-attachments'"),
);
check(
  "synchronisation réelle conditionnelle",
  has(script, "row.settings?.export_activities===true") &&
    has(script, "row.settings?.sync_mode==='bidirectional'") &&
    has(script, "action:'push_activity'"),
);
check(
  "échec de synchronisation visible",
  has(script, "sa synchronisation agenda a échoué"),
);
check(
  "création depuis entités",
  has(script, "openActivityForEntity:openForEntity") &&
    has(crm, "openActivityForEntity"),
);
check(
  "raccourci noter un appel",
  has(script, "openQuickCallWorkspace") && has(script, "type.slug==='call'"),
);
check(
  "types modifiables et désactivables",
  has(script, "editActivityTypeWorkspace") &&
    has(script, "toggleActivityTypeWorkspace") &&
    has(security, "'all_types'"),
);
check(
  "filtres sauvegardés sécurisés",
  has(script, "saveActivitySavedFilter") &&
    has(script, "applyActivitySavedFilter") &&
    has(security, "saved_filter.user_id=auth.uid()"),
);
check(
  "actions groupées",
  has(script, "bulkActivityAction") &&
    has(script, "selectAllActivities") &&
    has(script, "openBulkActivityStatus") &&
    has(script, "openBulkActivityAssign"),
);
check("glisser déposer agenda", has(script, "dropActivityOnDate:dragDrop"));
check(
  "accessibilité modale",
  has(script, 'role="dialog" aria-modal="true"') &&
    has(script, 'aria-label="Fermer"'),
);
check("fermeture échap", has(script, "event.key==='Escape'"));
check(
  "responsive tablette et mobile",
  has(css, "@media (max-width: 1280px)") &&
    has(css, "@media (max-width: 780px)") &&
    has(css, "@media (max-width: 480px)"),
);
check("mouvement réduit", /prefers-reduced-motion\s*:\s*reduce/.test(css));
check("focus visible", has(css, ":focus-visible"));
check(
  "z-index modale",
  /\.aw-modal-layer\s*\{[^}]*z-index:\s*100000/.test(css),
);

for (const slug of [
  "planifier-une-activite-commerciale",
  "terminer-activite-et-planifier-suite",
  "utiliser-vues-activites-agenda-equipe",
  "confidentialite-et-droits-des-activites",
  "synchroniser-activites-avec-agenda",
  "pieces-jointes-et-historique-activites",
]) {
  check(`documentation Pilo ${slug}`, has(knowledge, slug));
}
for (const file of [
  "ACTIVITIES_MODULE_AUDIT.md",
  "ACTIVITIES_ARCHITECTURE.md",
  "ACTIVITIES_DATA_MODEL.md",
  "ACTIVITIES_PERMISSIONS.md",
  "ACTIVITIES_MIGRATION_REPORT.md",
  "ACTIVITIES_TEST_REPORT.md",
  "ACTIVITIES_USER_GUIDE.md",
]) {
  check(
    `documentation ${file}`,
    fs.existsSync(path.join(root, "docs/activities", file)),
  );
}

console.log(
  `Activités workspace static: ${checks.length}/${checks.length} contrôles réussis.`,
);
