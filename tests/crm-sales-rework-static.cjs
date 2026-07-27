const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const assert=(value,message)=>{if(!value)throw new Error(message);};

const migration=read('supabase/migrations/202607270092_crm_sales_rework.sql');
const ui=read('assets/js/modules/erp/erp-crm-rework.js');
const css=read('assets/css/crm-rework.css');
const nav=read('assets/js/modules/erp/erp-modern.js');
const access=read('assets/js/modules/erp/erp-access-control.js');

for(const rpc of ['recalculate_crm_opportunity_amount','get_crm_party_picker','create_crm_party','save_crm_opportunity_v2','save_crm_activity_v2','link_crm_opportunity_document']){
  assert(migration.includes(`function public.${rpc}`),`RPC ${rpc} absente`);
}
for(const stage of ['Nouveau','À qualifier','Qualifié','Rendez-vous planifié','Besoin identifié','Devis à préparer','Devis envoyé','Gagné','Perdu']){
  assert(migration.includes(`'${stage}'`),`étape ${stage} absente`);
}
assert(migration.includes("member.role not in('auditor','read_only')"),'barrière lecture seule absente');
assert(migration.includes("crm_relation_type in('primary','variant','complement','replaced')"),'relations documentaires non qualifiées');
assert(migration.includes("coalesce(document.crm_relation_type,'primary') in('primary','complement')"),'montant documentaire non canonique');
assert(migration.includes('origin_prospect_id=coalesce(origin_prospect_id,prospect.id)'),'conversion prospect non traçable');
assert(migration.includes('update public.opportunities set client_id=target.id'),'opportunité non conservée à la conversion');
assert(migration.includes("'comparison',jsonb_build_object"),'comparaison de période serveur absente');
assert(migration.includes("'forecast',jsonb_build_object"),'prévisions commerciales serveur absentes');

assert(nav.includes("crm:{label:'Suivi commercial',items:[['crm/pipeline','Pipeline'],['crm/activities','Activités'],['crm/reports','Rapports commerciaux']]"),'menu CRM non conforme');
assert(nav.includes("['library/prospects','Prospects']"),'Prospects non déplacés dans Bibliothèque');
assert(access.includes("'library/prospects':['crm.prospects.read']"),'permission de la nouvelle route Prospects absente');

for(const token of ['crm-modal-layer','crm-party-button','crm-quick-party-form','crm-context-menu','crm-week-grid','crm-report-grid']){
  assert(ui.includes(token),`composant ${token} absent`);
}
for(const token of ['Période précédente','Analyse des devis','Prévisions','crm-report-delta'])assert(ui.includes(token),`rapport ${token} absent`);
for(const token of ['name="contact_id"','name="document_id"','name="meeting_url"','cancelActivity'])assert(ui.includes(token),`activité enrichie ${token} absente`);
assert(css.includes('position:fixed')&&css.includes('width:min(780px'),'modale CRM non centrée');
assert(css.includes('@media(max-width:900px)')&&css.includes('@media(max-width:560px)'),'responsive CRM absent');
assert(ui.includes('pipelineDecorationScheduled')&&ui.includes('requestAnimationFrame(()=>{pipelineDecorationScheduled=false'),'protection anti-boucle de rendu du pipeline absente');
assert(ui.includes("option.textContent!==priorityLabel")&&!ui.includes("queueMicrotask(decoratePipeline)"),'décoration du pipeline non idempotente');

process.stdout.write(JSON.stringify({ok:true,navigation:true,pipeline:true,pipeline_render_guard:true,party_picker:true,opportunity_modal:true,context_actions:true,activities:true,reports:true,document_amount:true,prospect_conversion:true,security:true,responsive:true})+'\n');
