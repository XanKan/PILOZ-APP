const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const assert=(value,message)=>{if(!value)throw new Error(message);};

const index=read('index.html');
const app=read('assets/js/modules/erp/erp-app.js');
const nav=read('assets/js/modules/erp/erp-modern.js');
const crm=read('assets/js/modules/erp/erp-crm-command-center.js');
const enterprise=read('assets/js/modules/erp/erp-crm-enterprise.js');
const dashboard=read('assets/js/modules/erp/erp-dashboard-cockpit.js');
const css=read('assets/css/crm-command-center.css');
const migration=read('supabase/migrations/202607260077_crm_command_center.sql');
const enterpriseMigration=read('supabase/migrations/202607260078_crm_enterprise_operations.sql');
const workspaceMigration=read('supabase/migrations/202607260079_crm_enterprise_workspace.sql');
const integrations=read('supabase/functions/external-integrations/index.ts');

assert(index.includes('assets/css/crm-command-center.css')&&index.includes('assets/js/modules/erp/erp-crm-command-center.js')&&index.includes('assets/js/modules/erp/erp-crm-enterprise.js'),'assets CRM non chargés');
const crmNavigation=nav.match(/crm:\{label:'Suivi commercial',items:\[[^\n]+/)?.[0]||'';
assert(crmNavigation.includes("['crm/pipeline','Pipeline']")&&crmNavigation.includes("['crm/prospects','Prospects']")&&crmNavigation.includes("['crm/activities','Activités']")&&crmNavigation.includes("['crm/automations','Automatisations']")&&crmNavigation.includes("['crm/reports','Rapports CRM']"),'navigation Suivi commercial incomplète');
assert(!crmNavigation.includes("Vue d’ensemble"),'Vue d’ensemble CRM encore affichée');
assert(!crmNavigation.includes("Opportunités"),'entrée Opportunités séparée encore affichée');
assert(app.includes("path.startsWith('crm/')"),'routes CRM dynamiques non gérées');

for(const view of ['kanban','list','forecast','calendar'])assert(crm.includes(`['${view}'`)||crm.includes(`===\'${view}\'`)||crm.includes(`==='${view}'`),`vue ${view} absente`);
for(const route of ['crm/pipeline','crm/prospects','crm/activities','crm/automations','crm/reports'])assert(crm.includes(route),`route ${route} absente`);
assert(crm.includes("row.pipeline_stage_id=stageId")&&crm.includes("row.pipeline_stage_id=previous"),'optimisme/rollback du glisser-déposer absent');
assert(crm.includes("close_crm_opportunity")&&crm.includes("Motif de perte"),'clôture gagnée/perdue incomplète');
assert(crm.includes("get_crm_opportunity_detail")&&crm.includes("get_crm_prospect_detail"),'fiches détaillées non branchées');
assert(crm.includes("create_crm_activity")&&crm.includes("complete_crm_activity"),'cycle des activités incomplet');
assert(crm.includes("Recalculer")&&crm.includes("recalculate_crm_score"),'scoring explicable non branché');
assert(crm.includes("Aucun e-mail ne sera considéré comme envoyé")||crm.includes("aucun envoi ne sera simulé")||crm.includes("aucun envoi fictif"),'garde-fou connecteur e-mail absent');
assert(crm.includes('Journal d’exécution')&&crm.includes('retryAutomation'),'journal ou retry d’automatisation absent');
assert(crm.includes('text/csv')&&crm.includes('Exporter CSV'),'import/export CRM absent');
assert(enterprise.includes('reorder_crm_pipeline_stages')&&enterprise.includes('upsert_crm_pipeline_stage')&&enterprise.includes('update_crm_pipeline'),'administration avancée des pipelines absente');
assert(enterprise.includes('import_crm_prospects')&&enterprise.includes('crm-csv-map')&&enterprise.includes('target_duplicate_action'),'import CSV contrôlé non branché');
assert(enterprise.includes('merge_crm_prospects')&&enterprise.includes('mergeProspect'),'fusion de prospects absente');
assert(enterprise.includes('search_crm_global')&&enterprise.includes('ctrlKey'),'recherche CRM globale absente');
assert(enterprise.includes('save_client_contact')&&enterprise.includes('crm_opportunity_products'),'contacts ou produits prévisionnels non branchés');
assert(enterprise.includes('openCrmInbox')&&enterprise.includes('external_mail_links')&&enterprise.includes('update_crm_mail_link'),'boîte de réception CRM non branchée');
assert(enterprise.includes('reschedule_crm_activity')&&crm.includes('dropCrmActivity'),'agenda glisser-déposer non branché');
assert(enterprise.includes('save_crm_view')&&enterprise.includes('crm_saved_views'),'vues enregistrées non branchées');
assert(enterprise.includes('downloadProspectTemplate')&&enterprise.includes('modele-import-prospects-piloz.csv'),'modèle CSV absent');
assert(crm.includes('crm-report-toolbar')&&crm.includes('setReportFilter')&&crm.includes('printReports'),'filtres ou impression des rapports absents');

assert(dashboard.includes("get_dashboard_command_center")&&dashboard.includes('renderCrmPipeline'),'Command Center non connecté au CRM');
assert(dashboard.includes("pipeline_weighted")&&dashboard.includes("quick('opportunity')")&&dashboard.includes("quick('prospect')"),'KPI/actions CRM du tableau de bord absents');
assert(css.includes('@media(max-width:720px)')&&css.includes('@media(max-width:1150px)')&&css.includes('.crm-kanban')&&css.includes('.crm-drawer'),'responsive CRM incomplet');

for(const object of ['crm_pipelines','crm_automation_rules','crm_sequences','crm_score_history','crm_timeline_events','crm_saved_views'])assert(migration.includes(`public.${object}`),`objet SQL ${object} absent`);
for(const rpc of ['get_crm_pipeline_workspace','create_crm_prospect','convert_crm_prospect','move_crm_opportunity','close_crm_opportunity','get_dashboard_command_center'])assert(migration.includes(`function public.${rpc}`),`RPC ${rpc} absent`);
assert(migration.includes('security definer set search_path=public,pg_temp'),'search_path SQL non figé');
assert(migration.includes('crm_automation_runs_idempotency_idx')&&migration.includes('external_connector_required'),'automatisations non idempotentes ou envoi externe simulé');
assert(migration.includes('enable row level security')&&migration.includes('is_company_member(company_id)'),'RLS CRM absente');
for(const rpc of ['update_crm_pipeline','upsert_crm_pipeline_stage','reorder_crm_pipeline_stages','update_crm_opportunity','update_crm_prospect','merge_crm_prospects','import_crm_prospects','search_crm_global'])assert(enterpriseMigration.includes(`function public.${rpc}`),`RPC avancée ${rpc} absente`);
assert(enterpriseMigration.includes('security definer set search_path=public,pg_temp'),'search_path des RPC avancées non figé');
for(const rpc of ['reschedule_crm_activity','save_crm_view','update_crm_mail_link','search_crm_global','retry_crm_automation_run'])assert(workspaceMigration.includes(`function public.${rpc}`),`RPC espace de travail ${rpc} absente`);
assert(workspaceMigration.includes("has_company_permission(company_id,''manage_opportunity'')")&&workspaceMigration.includes('crm_configuration_rls'),'durcissement RLS CRM absent');
assert(workspaceMigration.includes("extensions_manage_global")&&workspaceMigration.includes("connection.user_id=auth.uid()"),'isolation des messageries absente');
assert(integrations.includes('treatment_status:"processed"')&&integrations.includes('preview:String(content||"").slice(0,300)'),'historique réel des e-mails sortants incomplet');

process.stdout.write(JSON.stringify({ok:true,navigation:true,routes:true,views:4,drag_drop:true,pipeline_management:true,details:true,contacts:true,products:true,import:true,merge:true,global_search:true,crm_inbox:true,saved_views:true,activity_calendar:true,activities:true,automations:true,automation_retry:true,reports:true,dashboard:true,responsive:true,security:true})+'\n');
