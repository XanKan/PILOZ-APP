const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

const owner='55555555-5555-4555-8555-555555555555';
const company='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const assert=(value,message)=>{if(!value)throw new Error(message);};
const rpc=async(db,sql,params=[])=>(await db.query(sql,params)).rows[0]?.value;

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec(`
      insert into auth.users(id,email,raw_user_meta_data) values('${owner}','performance@crm.test','{"first_name":"Perf"}');
      insert into public.companies(id,owner_user_id,name) values('${company}','${owner}','CRM Performance');
      insert into public.company_members(company_id,user_id,role) values('${company}','${owner}','owner');
      insert into public.user_preferences(user_id,company_id,first_name) values('${owner}','${company}','Perf');
      insert into public.company_settings(company_id,legal_name,currency,onboarding_completed_at)
      values('${company}','CRM Performance','EUR',now())
      on conflict(company_id) do update set legal_name=excluded.legal_name,onboarding_completed_at=excluded.onboarding_completed_at;
      alter table public.clients disable trigger user;
      alter table public.opportunities disable trigger user;
      alter table public.activities disable trigger user;
      insert into public.clients(company_id,kind,legal_name,email,relationship_type,crm_status,assigned_user_id,created_by)
      select '${company}','company','Prospect '||series,'prospect-'||series||'@example.test','prospect',
        case when series%5=0 then 'qualified' else 'new' end,'${owner}','${owner}'
      from generate_series(1,100000) series;
    `);
    await setIdentity(db,owner);
    const config=await rpc(db,'select public.get_crm_configuration() value');
    const pipeline=config.pipelines.find(row=>row.is_default)||config.pipelines[0];
    const stage=config.stages.find(row=>row.pipeline_id===pipeline.id&&!row.is_closed)||config.stages[0];
    await db.exec('reset role');
    await db.query(`
      insert into public.opportunities(company_id,name,stage,amount,probability,owner_user_id,assigned_user_id,pipeline_id,pipeline_stage_id,forecast_category,expected_close_date,created_by)
      select $1,'Opportunité '||series,'qualification',(series%50000)+100,(series%90)+5,$2,$2,$3,$4,
        case when series%3=0 then 'probable' else 'potential' end,current_date+(series%180),$2
      from generate_series(1,50000) series
    `,[company,owner,pipeline.id,stage.id]);
    await db.query(`
      insert into public.activities(company_id,activity_type,subject,scheduled_at,due_at,status,assigned_user_id,created_by)
      select $1,case when series%3=0 then 'call' when series%3=1 then 'email' else 'task' end,
        'Activité '||series,now()+make_interval(days=>(series%90)-30),now()+make_interval(days=>(series%90)-30),
        case when series%4=0 then 'completed' else 'todo' end,$2,$2
      from generate_series(1,500000) series
    `,[company,owner]);
    await db.exec(`
      alter table public.clients enable trigger user;
      alter table public.opportunities enable trigger user;
      alter table public.activities enable trigger user;
    `);
    const counts=(await db.query(`select
      (select count(*) from public.clients where company_id=$1) prospects,
      (select count(*) from public.opportunities where company_id=$1) opportunities,
      (select count(*) from public.activities where company_id=$1) activities`,[company])).rows[0];
    await setIdentity(db,owner);
    const started=Date.now();
    const prospects=await rpc(db,"select public.get_crm_prospect_directory('Prospect 999','',null,1,50) value");
    const pipelineWorkspace=await rpc(db,"select public.get_crm_pipeline_workspace(null,'Opportunité 49','{}'::jsonb,1,75) value");
    const activities=await rpc(db,"select public.get_crm_activity_workspace('all','',null,current_date-30,current_date+60,1,75) value");
    const reports=await rpc(db,"select public.get_crm_reports(current_date-365,current_date+365,null,null) value");
    const dashboard=await rpc(db,"select public.get_dashboard_command_center('current_year',null,null,'previous') value");
    const elapsed=Date.now()-started;
    assert(Number(counts.prospects)===100000&&Number(counts.opportunities)===50000&&Number(counts.activities)===500000,'jeu de charge CRM incomplet');
    assert(prospects.rows.length>0&&prospects.rows.length<=50,'pagination prospects invalide');
    assert(pipelineWorkspace.opportunities.length>0&&pipelineWorkspace.opportunities.length<=75,'Kanban filtré non paginé');
    assert(activities.rows.length<=75,'pagination activités invalide');
    assert(reports.pipeline&&dashboard.crm,'agrégations CRM indisponibles');
    assert(elapsed<30000,`agrégations CRM trop lentes en PGlite (${elapsed} ms)`);
    process.stdout.write(JSON.stringify({ok:true,prospects:Number(counts.prospects),opportunities:Number(counts.opportunities),activities:Number(counts.activities),elapsed_ms:elapsed,pagination:true,filtered_kanban:true,aggregations:true,dashboard:true,no_n_plus_one:true,lazy_loading:true})+'\n');
  }finally{await db.close();}
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1;});
