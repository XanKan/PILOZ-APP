const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

const owner='91111111-1111-4111-8111-111111111111';
const reader='92222222-2222-4222-8222-222222222222';
const otherOwner='93333333-3333-4333-8333-333333333333';
const company='9aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherCompany='9bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const expectedStages=['Nouveau','À qualifier','Qualifié','Rendez-vous planifié','Besoin identifié','Devis à préparer','Devis envoyé','Gagné','Perdu'];

function assert(value,message){if(!value)throw new Error(message);}
async function rpc(db,sql,params=[]){return (await db.query(sql,params)).rows[0]?.value;}
async function expectError(promise,label){const error=await promise.then(()=>null,value=>value);if(!error)throw new Error(`${label}: erreur attendue absente`);return error;}

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec(`
      insert into auth.users(id,email) values
        ('${owner}','owner@crm-rework.test'),('${reader}','reader@crm-rework.test'),('${otherOwner}','other@crm-rework.test');
      insert into public.companies(id,owner_user_id,name) values
        ('${company}','${owner}','CRM Rework'),('${otherCompany}','${otherOwner}','Autre entreprise');
      insert into public.company_members(company_id,user_id,role) values
        ('${company}','${owner}','owner'),('${company}','${reader}','read_only'),('${otherCompany}','${otherOwner}','owner');
      update public.company_members set permissions=permissions||'{"crm.opportunities.read":true}'::jsonb
      where company_id='${company}' and user_id='${reader}';
      insert into public.user_preferences(user_id,company_id,first_name) values
        ('${owner}','${company}','Alice'),('${reader}','${company}','Rita'),('${otherOwner}','${otherCompany}','Bob');
      insert into public.company_settings(company_id,legal_name,siret,email,address_line1,postal_code,city,currency,onboarding_completed_at) values
        ('${company}','CRM Rework','12345678900011','crm@rework.test','1 rue du CRM','75001','Paris','EUR',now()),
        ('${otherCompany}','Autre entreprise','12345678900029','other@rework.test','2 rue du CRM','69001','Lyon','EUR',now())
      on conflict(company_id) do update set legal_name=excluded.legal_name,siret=excluded.siret,email=excluded.email,address_line1=excluded.address_line1,
        postal_code=excluded.postal_code,city=excluded.city,onboarding_completed_at=excluded.onboarding_completed_at;
    `);

    await setIdentity(db,owner);
    const configuration=await rpc(db,'select public.get_crm_configuration() value');
    const pipeline=configuration.pipelines.find(row=>row.is_default);
    const stages=configuration.stages.filter(row=>row.pipeline_id===pipeline.id&&row.active).sort((a,b)=>Number(a.position)-Number(b.position));
    assert(JSON.stringify(stages.map(row=>row.name))===JSON.stringify(expectedStages),`pipeline commercial actif non conforme: ${stages.map(row=>row.name).join(' | ')}`);

    const prospect=await rpc(db,"select to_jsonb(public.create_crm_party($1::jsonb)) value",[JSON.stringify({relationship_type:'prospect',kind:'company',legal_name:'Société Atlas',trade_name:'Atlas',legal_form:'SAS',first_name:'Alice',last_name:'Martin',contact_name:'Alice Martin',email:'atlas@crm.test',phone_e164:'+33102030405',siren:'123456789',siret:'12345678900011',ape_code:'6201Z',address_line_1:'12 rue des Fleurs',postal_code:'75001',city:'Paris',country_code:'FR'})]);
    assert(prospect.relationship_type==='prospect'&&prospect.company_id===company,'création rapide prospect invalide');
    assert(prospect.siret==='12345678900011'&&prospect.legal_form==='SAS'&&prospect.ape_code==='6201Z'&&prospect.address_line_1==='12 rue des Fleurs'&&prospect.postal_code==='75001'&&prospect.city==='Paris','données officielles INPI non conservées');
    await db.exec('reset role');
    const primaryContact=(await db.query("select first_name,last_name,email,phone_e164,is_primary from public.client_contacts where client_id=$1",[prospect.id])).rows[0];
    assert(primaryContact?.first_name==='Alice'&&primaryContact?.last_name==='Martin'&&primaryContact?.email==='atlas@crm.test'&&primaryContact?.phone_e164==='+33102030405'&&primaryContact?.is_primary===true,'contact principal non créé avec le client');
    await setIdentity(db,owner);
    const picker=await rpc(db,"select public.get_crm_party_picker('atlas',6,null) value");
    assert(picker.rows.length===1&&picker.rows[0].id===prospect.id,'recherche multi-champs du sélecteur tiers invalide');

    const opportunity=await rpc(db,"select to_jsonb(public.save_crm_opportunity_v2(null,$1::jsonb)) value",[JSON.stringify({name:'Projet Atlas',client_id:prospect.id,pipeline_id:pipeline.id,stage_id:stages[0].id,estimated_amount:1250,probability:15,expected_close_date:'2026-09-30',assigned_user_id:owner,priority:'high',next_action:'Qualifier le besoin',tags:['entrant','prioritaire']})]);
    assert(Number(opportunity.amount)===1250&&opportunity.amount_source==='estimated'&&opportunity.origin_prospect_id===prospect.id,'montant estimé ou origine prospect invalide');

    await db.exec('reset role');
    const draftQuote=(await db.query("insert into public.documents(company_id,document_type,status,issue_date,client_id,total_excl_tax,total_tax,total_incl_tax,opportunity_id,crm_relation_type,created_by) values($1,'quote','draft',current_date,$2,900,180,1080,$3,'primary',$4) returning id",[company,prospect.id,opportunity.id,owner])).rows[0];
    await db.query("insert into public.document_lines(company_id,document_id,position,line_type,name,quantity,unit_price,tax_rate,total_excl_tax,total_tax,total_incl_tax,created_by) values($1,$2,1,'item','Mission principale',1,900,20,900,180,1080,$3)",[company,draftQuote.id,owner]);
    let amount=(await db.query('select amount,documentary_amount,amount_source from public.opportunities where id=$1',[opportunity.id])).rows[0];
    assert(Number(amount.amount)===1250&&amount.amount_source==='estimated','un devis brouillon ne doit pas remplacer l’estimation');

    await db.query("update public.documents set status='sent' where id=$1",[draftQuote.id]);
    amount=(await db.query('select amount,documentary_amount,amount_source from public.opportunities where id=$1',[opportunity.id])).rows[0];
    assert(Number(amount.amount)===900&&Number(amount.documentary_amount)===900&&amount.amount_source==='documentary',`devis actif non repris comme montant canonique: ${JSON.stringify(amount)}`);

    const complement=(await db.query("insert into public.documents(company_id,document_type,status,issue_date,client_id,total_excl_tax,total_tax,total_incl_tax,opportunity_id,crm_relation_type,created_by) values($1,'quote','draft',current_date,$2,100,20,120,$3,'complement',$4) returning id",[company,prospect.id,opportunity.id,owner])).rows[0];
    const variant=(await db.query("insert into public.documents(company_id,document_type,status,issue_date,client_id,total_excl_tax,total_tax,total_incl_tax,opportunity_id,crm_relation_type,created_by) values($1,'quote','draft',current_date,$2,500,100,600,$3,'variant',$4) returning id",[company,prospect.id,opportunity.id,owner])).rows[0];
    await db.query("insert into public.document_lines(company_id,document_id,position,line_type,name,quantity,unit_price,tax_rate,total_excl_tax,total_tax,total_incl_tax,created_by) values($1,$2,1,'item','Complément',1,100,20,100,20,120,$4),($1,$3,1,'item','Variante',1,500,20,500,100,600,$4)",[company,complement.id,variant.id,owner]);
    await db.query("update public.documents set status='sent' where id in($1,$2)",[complement.id,variant.id]);
    amount=(await db.query('select amount,documentary_amount from public.opportunities where id=$1',[opportunity.id])).rows[0];
    assert(Number(amount.amount)===1000&&Number(amount.documentary_amount)===1000,'complément ou variante mal comptabilisé');

    await setIdentity(db,owner);
    const target=await rpc(db,"select to_jsonb(public.create_crm_party($1::jsonb)) value",[JSON.stringify({relationship_type:'client',kind:'company',legal_name:'Atlas Client',email:'client@atlas.test'})]);
    const converted=await rpc(db,'select public.convert_crm_prospect($1,$2) value',[prospect.id,target.id]);
    await db.exec('reset role');
    const preserved=(await db.query('select id,client_id,origin_prospect_id from public.opportunities where id=$1',[opportunity.id])).rows[0];
    assert(converted.client_id===target.id&&preserved.id===opportunity.id&&preserved.client_id===target.id&&preserved.origin_prospect_id===prospect.id,'conversion prospect destructive ou non traçable');

    const activity=await rpc(db,"select to_jsonb(public.create_crm_activity($1::jsonb)) value",[JSON.stringify({activity_type:'visit',subject:'Visite de qualification',opportunity_id:opportunity.id,client_id:target.id,due_at:new Date().toISOString(),priority:'high',assigned_user_id:owner})]);
    assert(activity.activity_type==='visit'&&activity.opportunity_id===opportunity.id,'création d’activité CRM enrichie invalide');
    const editedActivity=await rpc(db,"select to_jsonb(public.save_crm_activity_v2($1,$2::jsonb)) value",[activity.id,JSON.stringify({activity_type:'visit',status:'in_progress',subject:'Visite de qualification confirmée',opportunity_id:opportunity.id,client_id:target.id,document_id:draftQuote.id,due_at:new Date().toISOString(),duration_minutes:45,priority:'high',assigned_user_id:owner,location:'Chez le client',meeting_url:'https://meet.example.test/crm'})]);
    assert(editedActivity.status==='in_progress'&&editedActivity.document_id===draftQuote.id&&editedActivity.location==='Chez le client','modification sécurisée ou rattachements activité invalides');
    const completed=await rpc(db,"select public.complete_crm_activity_v2($1,$2,$3,$4,now()+interval '1 day',$5) value",[activity.id,'positive','Besoin confirmé','Envoyer le devis',stages[1].id]);
    assert(completed.activity.status==='completed'&&completed.next_activity?.subject==='Envoyer le devis'&&completed.stage_id===stages[1].id,'clôture atomique ou prochaine action invalide');
    const activityWorkspace=await rpc(db,"select public.get_crm_activity_workspace('today','all',null,current_date-1,current_date+2,1,200) value");
    assert(activityWorkspace.rows.some(row=>row.id===activity.id)&&activityWorkspace.rows.some(row=>row.id===completed.next_activity.id),'centre d’activités incomplet');
    const workspaceV3=await rpc(db,"select public.get_activity_workspace_v3('list','all',null,null,null,null,null,null,null,false,1,50) value");
    assert(workspaceV3.types.some(row=>row.slug==='call')&&workspaceV3.types.some(row=>row.slug==='payment_followup'),'types d’activités complets absents');
    assert(Array.isArray(workspaceV3.all_types)&&Array.isArray(workspaceV3.saved_filters),'configuration et filtres du workspace absents');
    const callType=workspaceV3.types.find(row=>row.slug==='call');
    const workspaceCreated=await rpc(db,"select to_jsonb(public.save_activity_workspace(null,$1::jsonb)) value",[JSON.stringify({activity_type_id:callType.id,subject:'Appel de recette workspace',status:'scheduled',priority:'urgent',starts_at:new Date().toISOString(),duration_minutes:30,assigned_user_id:owner,confidentiality:'private',links:[{entity_type:'client',entity_id:target.id},{entity_type:'opportunity',entity_id:opportunity.id}],checklist:[{label:'Confirmer le besoin',position:0}],reminders:[{channel:'in_app',remind_at:new Date(Date.now()+3600000).toISOString(),recipient_user_id:owner}]})]);
    const workspaceDetail=await rpc(db,'select public.get_activity_detail($1) value',[workspaceCreated.id]);
    assert(workspaceDetail.activity.confidentiality==='private'&&workspaceDetail.links.length===2&&workspaceDetail.checklist.length===1&&workspaceDetail.reminders.length===1,'détail activité, confidentialité ou sous-objets invalides');
    const savedFilter=await rpc(db,"select to_jsonb(public.save_activity_saved_filter(null,'Mes appels urgents','list',$1::jsonb)) value",[JSON.stringify({type_id:callType.id,status:'scheduled',quick:'all'})]);
    const workspaceWithFilter=await rpc(db,"select public.get_activity_workspace_v3('list','all',null,null,null,null,null,null,null,false,1,50) value");
    assert(workspaceWithFilter.saved_filters.some(row=>row.id===savedFilter.id&&row.user_id===owner),'filtre sauvegardé absent du workspace');
    assert(await rpc(db,'select public.delete_activity_saved_filter($1) value',[savedFilter.id])===true,'suppression du filtre personnel impossible');
    const transitioned=await rpc(db,"select to_jsonb(public.transition_activity_workspace($1,'status','{\"status\":\"in_progress\"}'::jsonb)) value",[workspaceCreated.id]);
    assert(transitioned.status==='in_progress','transition de statut activité invalide');
    const savedPreferences=await rpc(db,"select to_jsonb(public.save_activity_workspace_preferences($1::jsonb)) value",[JSON.stringify({default_view:'team',page_size:100,density:'compact',show_metrics:false,visible_columns:['subject','owner','date','status'],sort_key:'subject',sort_direction:'desc'})]);
    assert(savedPreferences.page_size===100&&savedPreferences.density==='compact'&&savedPreferences.show_metrics===false,'activity workspace preferences were not persisted');
    const workspaceV4=await rpc(db,"select public.get_activity_workspace_v4('list','all',null,null,null,null,null,null,null,false,1,100,'subject','desc') value");
    assert(Array.isArray(workspaceV4.rows)&&workspaceV4.page_size===100&&workspaceV4.preferences.default_view==='team','activity workspace v4 is incomplete');
    assert(Number(workspaceV4.counts.today)>=0&&Number(workspaceV4.counts.unassigned)>=0,'activity workspace v4 counters are missing');
    const relationSearch=await rpc(db,"select coalesce(jsonb_agg(to_jsonb(candidate)),'[]'::jsonb) value from public.search_activity_relations('all','Atlas',20) candidate");
    assert(relationSearch.some(row=>row.entity_id===target.id)&&relationSearch.some(row=>row.entity_id===opportunity.id),'server-side activity relation search is incomplete');
    const workspaceCopy=await rpc(db,'select to_jsonb(public.duplicate_activity_workspace($1)) value',[workspaceCreated.id]);
    const bulkResult=await rpc(db,"select public.bulk_transition_activities_workspace(array[$1::uuid,$2::uuid],'status','{\"status\":\"scheduled\"}'::jsonb) value",[workspaceCreated.id,workspaceCopy.id]);
    assert(Number(bulkResult.changed)===2&&bulkResult.failed.length===0,'bulk activity transition failed');
    const reports=await rpc(db,"select public.get_crm_reports(date_trunc('month',current_date)::date,current_date,null,null) value");
    assert(reports.permissions.export===true&&reports.metrics.pipeline_count>=1&&reports.quotes.created>=3,`agrégats commerciaux serveur invalides: ${JSON.stringify(reports)}`);
    assert(reports.comparison?.start&&reports.comparison?.end,'comparaison de période absente');
    assert(Number(reports.forecast?.gross)>=0&&Array.isArray(reports.forecast?.buckets),'prévisions commerciales serveur absentes');
    assert(Number(reports.activities?.completion_rate)>=0&&Number(reports.quotes?.acceptance_rate)>=0,'taux activités/devis absents');

    await setIdentity(db,otherOwner);
    const isolated=await rpc(db,"select public.get_crm_party_picker('Atlas',25,null) value");
    assert(isolated.rows.length===0,'fuite inter-entreprise du sélecteur tiers');

    const isolatedActivities=await rpc(db,"select public.get_activity_workspace_v4('list','all',null,null,null,null,null,null,null,true,1,100,'activity_at','asc') value");
    assert(!isolatedActivities.rows.some(row=>row.id===workspaceCreated.id),'activity workspace tenant isolation failed');

    await setIdentity(db,reader);
    await expectError(rpc(db,"select to_jsonb(public.create_crm_party('{\"relationship_type\":\"prospect\",\"kind\":\"company\",\"legal_name\":\"Interdit\"}'::jsonb)) value"),'écriture lecteur seule');
    const before=(await rpc(db,"select public.get_crm_pipeline_workspace(null,null,'{}'::jsonb,1,75) value")).opportunities.find(row=>row.id===opportunity.id).name;
    await db.query("update public.opportunities set name='Modification interdite' where id=$1",[opportunity.id]).catch(()=>null);
    const after=(await rpc(db,"select public.get_crm_pipeline_workspace(null,null,'{}'::jsonb,1,75) value")).opportunities.find(row=>row.id===opportunity.id).name;
    assert(before===after,'RLS lecteur seule contournable en accès direct');

    const readerActivities=await rpc(db,"select public.get_activity_workspace_v4('list','all',null,null,null,null,null,null,null,true,1,100,'activity_at','asc') value");
    assert(!readerActivities.rows.some(row=>row.id===workspaceCreated.id),'private activity leaked to read-only user');
    const forbiddenBulk=await rpc(db,"select public.bulk_transition_activities_workspace(array[$1::uuid],'status','{\"status\":\"completed\"}'::jsonb) value",[workspaceCreated.id]);
    assert(Number(forbiddenBulk.changed)===0&&Number(forbiddenBulk.skipped)===1,'read-only user changed an activity through bulk action');

    process.stdout.write(JSON.stringify({ok:true,stages:stages.length,party_picker:true,quick_create:true,primary_contact:true,inpi_details:true,opportunity:true,document_amount:true,conversion:true,activities:true,activity_workspace_v3:true,activity_workspace_v4:true,workspace_preferences:true,relation_search:true,bulk_actions:true,saved_filters:true,confidentiality:true,reports:true,comparison:true,forecast:true,tenant_isolation:true,read_only:true})+'\n');
  }finally{await db.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
