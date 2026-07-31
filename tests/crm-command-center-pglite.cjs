const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

const owner='11111111-1111-4111-8111-111111111111';
const reader='22222222-2222-4222-8222-222222222222';
const otherOwner='33333333-3333-4333-8333-333333333333';
const seller='44444444-4444-4444-8444-444444444444';
const companyA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const companyB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

function assert(value,message){if(!value)throw new Error(message);}
async function rpc(db,sql,params=[]){return (await db.query(sql,params)).rows[0]?.value;}
async function expectError(promise,label){const error=await promise.then(()=>null,value=>value);if(!error)throw new Error(`${label}: erreur attendue absente`);return error;}

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec(`
      insert into auth.users(id,email,raw_user_meta_data) values
        ('${owner}','owner@crm-a.test','{"first_name":"Alice"}'),
        ('${reader}','reader@crm-a.test','{"first_name":"Rita"}'),
        ('${seller}','seller@crm-a.test','{"first_name":"Sam"}'),
        ('${otherOwner}','owner@crm-b.test','{"first_name":"Bob"}');
      insert into public.companies(id,owner_user_id,name) values
        ('${companyA}','${owner}','CRM A'),('${companyB}','${otherOwner}','CRM B');
      insert into public.company_members(company_id,user_id,role) values
        ('${companyA}','${owner}','owner'),('${companyA}','${reader}','read_only'),
        ('${companyA}','${seller}','sales'),
        ('${companyB}','${otherOwner}','owner');
      insert into public.user_preferences(user_id,company_id,first_name) values
        ('${owner}','${companyA}','Alice'),('${reader}','${companyA}','Rita'),
        ('${seller}','${companyA}','Sam'),
        ('${otherOwner}','${companyB}','Bob');
      insert into public.company_settings(company_id,legal_name,currency,onboarding_completed_at) values
        ('${companyA}','CRM A','EUR',now()),('${companyB}','CRM B','EUR',now())
      on conflict(company_id) do update set legal_name=excluded.legal_name,currency=excluded.currency,onboarding_completed_at=excluded.onboarding_completed_at;
    `);

    await setIdentity(db,owner);
    const functions=(await db.query(`
      select proname,prosecdef,coalesce(array_to_string(proconfig,','),'') config
      from pg_proc join pg_namespace namespace on namespace.oid=pronamespace
      where namespace.nspname='public' and proname like '%crm%'
    `)).rows;
    assert(functions.length>=20,'fondation CRM incomplète');
    assert(functions.filter(row=>row.prosecdef).every(row=>String(row.config).includes('search_path=public, pg_temp')),'search_path CRM non figé');

    const config=await rpc(db,'select public.get_crm_configuration() value');
    assert(config.pipelines.length===1,'pipeline initial absent');
    assert(config.stages.length>=5,'étapes initiales absentes de la configuration');
    assert(config.sources.length>=4,'sources initiales absentes');
    assert(config.loss_reasons.length>=3,'motifs de perte initiaux absents');
    const pipeline=config.pipelines[0];
    const openStages=config.stages.filter(stage=>stage.pipeline_id===pipeline.id&&stage.stage_type==='open');
    assert(openStages.length>=2,'pipeline non exploitable');
    const renewal=await rpc(db,"select to_jsonb(public.create_crm_pipeline('Renouvellements',null,'EUR','renewal')) value");
    assert(renewal.pipeline_type==='renewal','création multi-pipeline invalide');
    const configAfterPipeline=await rpc(db,'select public.get_crm_configuration() value');
    const renewalStages=configAfterPipeline.stages.filter(stage=>stage.pipeline_id===renewal.id).length;
    assert(Number(renewalStages)===config.stages.length,'duplication des étapes du nouveau pipeline invalide');

    const updatedPipeline=await rpc(db,"select to_jsonb(public.update_crm_pipeline($1,$2::jsonb)) value",[renewal.id,JSON.stringify({name:'Renouvellements annuels',color:'#123456',status:'active'})]);
    assert(updatedPipeline.name==='Renouvellements annuels'&&updatedPipeline.color==='#123456','mise à jour pipeline invalide');
    const newStage=await rpc(db,"select to_jsonb(public.upsert_crm_pipeline_stage($1,$2::jsonb)) value",[renewal.id,JSON.stringify({name:'Validation juridique',slug:'validation_juridique',probability:65,stage_type:'open',color:'#654321'})]);
    assert(newStage.pipeline_id===renewal.id&&Number(newStage.probability)===65,'création étape avancée invalide');
    const renewalConfig=await rpc(db,'select public.get_crm_configuration() value');
    const renewalStageIds=renewalConfig.stages.filter(stage=>stage.pipeline_id===renewal.id).map(stage=>stage.id).reverse();
    await rpc(db,'select public.reorder_crm_pipeline_stages($1,$2::uuid[]) value',[renewal.id,renewalStageIds]);
    const reorderedConfig=await rpc(db,'select public.get_crm_configuration() value');
    const reorderedFirst=reorderedConfig.stages.filter(stage=>stage.pipeline_id===renewal.id).sort((left,right)=>Number(left.position)-Number(right.position))[0];
    assert(reorderedFirst.id===renewalStageIds[0],'réordonnancement des étapes non persisté');

    const prospect=await rpc(db,"select to_jsonb(public.create_crm_prospect($1::jsonb)) value",[JSON.stringify({kind:'company',legal_name:'Prospect Atlas',legal_form:'SAS',ape_code:'6201Z',email:'atlas@example.test',phone_e164:'+33102030405',siren:'123456789',siret:'12345678900011',assigned_user_id:owner})]);
    assert(prospect.relationship_type==='prospect'&&prospect.company_id===companyA&&prospect.legal_form==='SAS'&&prospect.ape_code==='6201Z'&&prospect.siren==='123456789','création prospect professionnel invalide');
    const individualProspect=await rpc(db,"select to_jsonb(public.create_crm_prospect($1::jsonb)) value",[JSON.stringify({kind:'person',civility:'Mme',first_name:'Claire',last_name:'Martin',legal_name:'Ne doit pas rester',legal_form:'SAS',siren:'999999999',siret:'99999999900011',ape_code:'6201Z'})]);
    assert(individualProspect.kind==='person'&&individualProspect.civility==='Mme'&&individualProspect.first_name==='Claire'&&individualProspect.last_name==='Martin'&&individualProspect.legal_name===null&&individualProspect.legal_form===null&&individualProspect.siren===null&&individualProspect.siret===null&&individualProspect.ape_code===null,'les champs professionnels du particulier ne sont pas nettoyés');
    await expectError(rpc(db,"select public.create_crm_prospect($1::jsonb) value",[JSON.stringify({kind:'company',legal_name:'Doublon',email:'ATLAS@example.test'})]),'anti-doublon prospect');

    const updatedProspect=await rpc(db,"select to_jsonb(public.update_crm_prospect($1,$2::jsonb)) value",[prospect.id,JSON.stringify({kind:'company',legal_name:'Prospect Atlas Conseil',email:'atlas@example.test',phone_e164:'+33102030405',city:'Paris',crm_status:'qualified'})]);
    assert(updatedProspect.legal_name==='Prospect Atlas Conseil'&&updatedProspect.city==='Paris','mise à jour prospect invalide');
    const importReport=await rpc(db,"select public.import_crm_prospects($1::jsonb,'skip') value",[JSON.stringify([{legal_name:'Import Alpha',email:'alpha@example.test',phone_e164:'+33601020304',source:'CSV'},{legal_name:'Import Bêta',email:'beta@example.test',city:'Lyon'}])]);
    assert(Number(importReport.created)===2&&Number(importReport.errors)===0,'import CSV de prospects invalide');
    const duplicateImport=await rpc(db,"select public.import_crm_prospects($1::jsonb,'update') value",[JSON.stringify([{legal_name:'Import Alpha actualisé',email:'alpha@example.test',city:'Nantes'}])]);
    assert(Number(duplicateImport.updated)===1,'stratégie de doublon import invalide');

    const opportunity=await rpc(db,"select to_jsonb(public.create_crm_opportunity($1::jsonb)) value",[JSON.stringify({name:'Contrat Atlas',client_id:prospect.id,pipeline_id:pipeline.id,stage_id:openStages[0].id,amount:12000,probability:40,expected_close_date:'2026-08-31',assigned_user_id:owner,next_action:'Présenter la proposition',priority:'high'})]);
    assert(opportunity.pipeline_stage_id===openStages[0].id&&Number(opportunity.amount)===12000,'création opportunité invalide');
    const updatedOpportunity=await rpc(db,"select to_jsonb(public.update_crm_opportunity($1,$2::jsonb)) value",[opportunity.id,JSON.stringify({name:'Contrat Atlas 2026',client_id:prospect.id,pipeline_id:pipeline.id,stage_id:openStages[0].id,amount:12500,probability:45,expected_close_date:'2026-09-15',assigned_user_id:owner,next_action:'Envoyer la proposition',priority:'urgent',description:'Contrat cadre'})]);
    assert(updatedOpportunity.name==='Contrat Atlas 2026'&&Number(updatedOpportunity.amount)===12500&&updatedOpportunity.priority==='urgent','mise à jour opportunité atomique invalide');
    await db.query("insert into public.crm_automation_rules(company_id,name,status,trigger_type,actions,created_by) values($1,'Préparer le suivi','active','opportunity_stage_changed','[{\"type\":\"create_activity\",\"subject\":\"Suivi automatique\",\"due_days\":2}]'::jsonb,$2)",[companyA,owner]);

    let workspace=await rpc(db,"select public.get_crm_pipeline_workspace(null,null,'{}'::jsonb,1,75) value");
    assert(workspace.opportunities.length===1,'opportunité absente du pipeline');
    assert(Number(workspace.summary.total_amount)===12500&&Number(workspace.summary.weighted_amount)===5625,'agrégats pipeline invalides');
    await rpc(db,'select public.move_crm_opportunity($1,$2) value',[opportunity.id,openStages[1].id]);
    workspace=await rpc(db,"select public.get_crm_pipeline_workspace(null,'Atlas','{}'::jsonb,1,75) value");
    assert(workspace.opportunities[0]?.pipeline_stage_id===openStages[1].id,'déplacement pipeline non persisté');
    const automationRun=(await db.query("select rule_id,status,output from public.crm_automation_runs where entity_id=$1 order by created_at desc limit 1",[opportunity.id])).rows[0];
    assert(automationRun?.status==='completed','automatisation non exécutée');

    const activity=await rpc(db,"select to_jsonb(public.create_crm_activity($1::jsonb)) value",[JSON.stringify({activity_type:'call',subject:'Appeler Atlas',client_id:prospect.id,opportunity_id:opportunity.id,due_at:'2026-07-27T09:00:00Z',assigned_user_id:owner,priority:'high'})]);
    const rescheduled=await rpc(db,'select to_jsonb(public.reschedule_crm_activity($1,$2,null)) value',[activity.id,'2026-07-29T14:30:00Z']);
    assert(new Date(rescheduled.due_at).toISOString().startsWith('2026-07-29T14:30:00'),'replanification agenda non persistée');
    assert(activity.status==='todo','création activité invalide');
    const completed=await rpc(db,"select to_jsonb(public.complete_crm_activity($1,'Décideur joint','Envoyer le devis')) value",[activity.id]);
    assert(completed.status==='completed'&&completed.next_action==='Envoyer le devis','activité non clôturée');
    const score=await rpc(db,"select public.recalculate_crm_score($1,'Test intégration') value",[prospect.id]);
    assert(Number(score.score)>=44&&score.explanation.length>=4,'score CRM inexpliqué ou invalide');

    await db.query("insert into public.crm_notes(company_id,entity_type,entity_id,body,is_pinned,created_by) values($1,'opportunity',$2,'Décision attendue vendredi',true,$3)",[companyA,opportunity.id,owner]);
    const detail=await rpc(db,'select public.get_crm_opportunity_detail($1) value',[opportunity.id]);
    assert(detail.activities.some(row=>row.subject==='Suivi automatique')&&detail.activities.some(row=>row.subject==='Appeler Atlas')&&detail.notes[0]?.content==='Décision attendue vendredi','détail opportunité incomplet');
    assert(detail.timeline.some(row=>row.event_type==='stage_changed'),'historique de changement d’étape absent');

    await db.exec('reset role');
    await db.query("insert into public.client_contacts(company_id,client_id,first_name,last_name,email,created_by) values($1,$2,'Ariane','Martin','ariane.atlas@example.test',$3)",[companyA,prospect.id,owner]);
    await setIdentity(db,owner);
    const globalSearch=await rpc(db,"select public.search_crm_global('Atlas',20) value");
    const contactSearch=await rpc(db,"select public.search_crm_global('Ariane',20) value");
    assert(globalSearch.some(row=>row.type==='prospect')&&globalSearch.some(row=>row.type==='opportunity')&&contactSearch.some(row=>row.type==='contact'),'recherche globale CRM incomplète');
    const savedView=await rpc(db,"select to_jsonb(public.save_crm_view(null,'pipeline','Mes affaires prioritaires','{\"priority\":\"high\"}'::jsonb,'[]'::jsonb,'[]'::jsonb,false,true)) value");
    const updatedView=await rpc(db,"select to_jsonb(public.save_crm_view(null,'pipeline','Mes affaires prioritaires','{\"priority\":\"urgent\"}'::jsonb,'[]'::jsonb,'[]'::jsonb,false,true)) value");
    assert(savedView.id===updatedView.id&&updatedView.filters.priority==='urgent'&&updatedView.is_default,'vue CRM non persistée ou non idempotente');

    await db.exec('reset role');
    const connection=(await db.query("insert into public.external_connections(company_id,user_id,provider,connection_scope,account_email,status,created_by) values($1,$2,'gmail','personal','owner@crm-a.test','connected',$2) returning id",[companyA,owner])).rows[0];
    const mail=(await db.query("insert into public.external_mail_links(company_id,connection_id,external_message_id,direction,sender,subject,preview,recipients,status,treatment_status,created_by) values($1,$2,'crm-mail-1','inbound','contact@example.test','Projet Atlas','Premier message CRM',array['owner@crm-a.test'],'recorded','new',$3) returning id",[companyA,connection.id,owner])).rows[0];
    await setIdentity(db,owner);
    const linkedMail=await rpc(db,"select public.update_crm_mail_link($1,$2::jsonb) value",[mail.id,JSON.stringify({client_id:prospect.id,opportunity_id:opportunity.id,assigned_user_id:owner,treatment_status:'processed'})]);
    assert(linkedMail.client_id===prospect.id&&linkedMail.opportunity_id===opportunity.id&&linkedMail.treatment_status==='processed','traitement de la boîte CRM invalide');
    const mergeSource=await rpc(db,"select to_jsonb(public.create_crm_prospect($1::jsonb)) value",[JSON.stringify({kind:'company',legal_name:'Atlas filiale',email:'filiale-atlas@example.test'})]);
    await rpc(db,"select to_jsonb(public.create_crm_activity($1::jsonb)) value",[JSON.stringify({activity_type:'call',subject:'Appel filiale',client_id:mergeSource.id})]);
    const mergeResult=await rpc(db,"select public.merge_crm_prospects($1,$2,'{}'::jsonb) value",[prospect.id,mergeSource.id]);
    const mergedDetail=await rpc(db,'select public.get_crm_prospect_detail($1) value',[prospect.id]);
    await db.exec('reset role');
    const mergedSource=(await db.query('select relationship_type,active from public.clients where id=$1',[mergeSource.id])).rows[0];
    await setIdentity(db,owner);
    assert(mergeResult.history_preserved===true&&mergedDetail.activities.some(row=>row.subject==='Appel filiale')&&mergedSource.relationship_type==='archived'&&!mergedSource.active,'fusion de prospects sans perte invalide');

    await expectError(rpc(db,"select public.close_crm_opportunity($1,'lost',null,null,'Test') value",[opportunity.id]),'motif de perte obligatoire');
    const lossReason=config.loss_reasons[0];
    const lost=await rpc(db,"select to_jsonb(public.close_crm_opportunity($1,'lost',11000,$2,'Budget reporté')) value",[opportunity.id,lossReason.id]);
    assert(lost.forecast_category==='lost'&&lost.lost_reason_id===lossReason.id,'clôture perdue invalide');
    const reopened=await rpc(db,"select to_jsonb(public.close_crm_opportunity($1,'reopen')) value",[opportunity.id]);
    assert(reopened.forecast_category==='potential'&&!reopened.closed_at,'réouverture invalide');
    const won=await rpc(db,"select to_jsonb(public.close_crm_opportunity($1,'won',11800,null,'Accord signé')) value",[opportunity.id]);
    assert(won.forecast_category==='won'&&Number(won.actual_amount)===11800,'clôture gagnée invalide');

    const conversion=await rpc(db,'select public.convert_crm_prospect($1,null) value',[prospect.id]);
    assert(conversion.client_id===prospect.id&&conversion.merged===false,'conversion prospect invalide');
    const converted=(await db.query('select relationship_type,crm_status from public.clients where id=$1',[prospect.id])).rows[0];
    assert(converted.relationship_type==='client'&&converted.crm_status==='converted','état client après conversion invalide');

    const reports=await rpc(db,"select public.get_crm_reports('2026-01-01','2026-12-31',null,null) value");
    assert(Number(reports.outcomes.won_count)===1&&Number(reports.outcomes.won_amount)===11800,'rapport CRM invalide');
    const dashboard=await rpc(db,"select public.get_dashboard_command_center('current_month',null,null,'previous') value");
    assert(dashboard.crm&&Number(dashboard.crm.open_opportunities)===0,'Command Center CRM invalide');

    await db.exec('reset role');
    const failedRun=(await db.query("insert into public.crm_automation_runs(company_id,rule_id,entity_type,entity_id,status,input,error_code,error_message,created_by,finished_at) values($1,$2,'opportunity',$3,'failed',$4::jsonb,'XX000','Échec contrôlé',$5,now()) returning id",[companyA,automationRun.rule_id,opportunity.id,JSON.stringify({row:{client_id:prospect.id,assigned_user_id:owner}}),owner])).rows[0];
    await setIdentity(db,owner);
    const retriedRun=await rpc(db,'select public.retry_crm_automation_run($1) value',[failedRun.id]);
    assert(retriedRun.status==='completed'&&Number(retriedRun.attempt)===2,'retry d’automatisation non exécuté');

    await setIdentity(db,reader);
    const readOnlyConfig=await rpc(db,'select public.get_crm_configuration() value');
    assert(readOnlyConfig.permissions.write===false,'permission lecture seule invalide');
    await expectError(rpc(db,"select public.create_crm_prospect($1::jsonb) value",[JSON.stringify({kind:'company',legal_name:'Interdit'})]),'écriture lecture seule');
    await expectError(rpc(db,"select public.update_crm_pipeline($1,$2::jsonb) value",[pipeline.id,JSON.stringify({name:'Interdit'})]),'pipeline lecture seule');
    await expectError(rpc(db,"select public.update_crm_opportunity($1,$2::jsonb) value",[opportunity.id,JSON.stringify({name:'Interdit'})]),'opportunité lecture seule');
    await expectError(rpc(db,"select public.import_crm_prospects($1::jsonb,'skip') value",[JSON.stringify([{legal_name:'Interdit'}])]),'import lecture seule');
    await expectError(rpc(db,'select public.reschedule_crm_activity($1,$2,null) value',[activity.id,'2026-08-01T09:00:00Z']),'agenda lecture seule');
    await expectError(rpc(db,'select public.retry_crm_automation_run($1) value',[failedRun.id]),'retry lecture seule');
    await expectError(rpc(db,"select public.update_crm_mail_link($1,$2::jsonb) value",[mail.id,JSON.stringify({treatment_status:'archived'})]),'boîte CRM personnelle croisée');
    await expectError(rpc(db,"select public.save_crm_view(null,'pipeline','Vue partagée interdite','{}'::jsonb,'[]'::jsonb,'[]'::jsonb,true,false) value"),'vue partagée lecture seule');
    await expectError(db.query("insert into public.crm_notes(company_id,entity_type,entity_id,body,created_by) values($1,'opportunity',$2,'Interdit',$3)",[companyA,opportunity.id,reader]),'RLS note lecture seule');

    await setIdentity(db,seller);
    const sellerReports=await rpc(db,"select public.get_crm_reports('2026-01-01','2026-12-31',null,null) value");
    const sellerWorkspace=await rpc(db,"select public.get_crm_pipeline_workspace(null,null,'{}'::jsonb,1,75) value");
    assert(Number(sellerReports.outcomes.won_count)===0&&sellerWorkspace.opportunities.length===0,'agrégats commerciaux non limités au responsable');

    await setIdentity(db,otherOwner);
    const isolated=await rpc(db,"select public.get_crm_pipeline_workspace(null,null,'{}'::jsonb,1,75) value");
    assert(isolated.opportunities.length===0&&isolated.pipeline.company_id===companyB,'isolation inter-entreprises invalide');
    const isolatedSearch=await rpc(db,"select public.search_crm_global('Atlas',20) value");
    assert(isolatedSearch.length===0,'recherche globale inter-entreprises non isolée');
    await expectError(rpc(db,'select public.get_crm_opportunity_detail($1) value',[opportunity.id]),'lecture croisée opportunité');

    await db.exec('reset role');
    await db.query("select set_config('request.jwt.claim.sub','',false)");
    await db.exec('set role anon');
    await expectError(rpc(db,'select public.get_crm_configuration() value'),'accès CRM anonyme');
    await expectError(rpc(db,"select public.search_crm_global('Atlas',20) value"),'recherche CRM anonyme');

    process.stdout.write(JSON.stringify({ok:true,migrations:79,pipelines:true,stages:config.stages.length,prospect:true,opportunity:true,drag_drop:true,activity_calendar:true,crm_inbox:true,saved_views:true,activities:true,automation:true,scoring:true,conversion:true,import:true,merge:true,global_search:true,reports:true,dashboard:true,rls:true})+'\n');
  }finally{await db.close();}
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1;});
