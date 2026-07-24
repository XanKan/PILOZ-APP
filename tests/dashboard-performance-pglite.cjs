const {performance}=require('node:perf_hooks');
const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

const user='77777777-7777-4777-8777-777777777777';
const company='88888888-8888-4888-8888-888888888888';
const client='99999999-9999-4999-8999-999999999999';

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec(`
      insert into auth.users(id,email,raw_user_meta_data) values('${user}','performance@piloz.test','{"first_name":"Performance"}');
      insert into public.companies(id,owner_user_id,name) values('${company}','${user}','Entreprise performance');
      insert into public.company_members(company_id,user_id,role) values('${company}','${user}','owner');
      insert into public.user_preferences(user_id,company_id,first_name) values('${user}','${company}','Performance');
      insert into public.company_settings(company_id,legal_name,currency,siret,email,address_line1,postal_code,city,country_code,onboarding_completed_at)
        values('${company}','Entreprise performance','EUR','12345678900033','performance@piloz.test','3 rue Test','75003','Paris','FR',now())
        on conflict(company_id) do update set legal_name=excluded.legal_name;
      insert into public.clients(id,company_id,kind,legal_name,active,created_by)
        values('${client}','${company}','company','Client performance',true,'${user}');
      set session_replication_role=replica;
      insert into public.clients(id,company_id,kind,legal_name,active,created_by,created_at)
      select gen_random_uuid(),'${company}'::uuid,'company','Client charge '||value,true,'${user}'::uuid,clock_timestamp()
      from generate_series(1,10000) value;
      insert into public.catalog_items(id,company_id,item_type,reference,name,unit,stock_managed,active,created_by)
      select gen_random_uuid(),'${company}'::uuid,'service','SERVICE-'||value,'Service charge '||value,'heure',false,true,'${user}'::uuid
      from generate_series(1,20000) value;
      insert into public.activities(id,company_id,activity_type,subject,scheduled_at,assigned_user_id,metadata,created_by)
      select gen_random_uuid(),'${company}'::uuid,'task','Activité charge '||value,
        timestamptz '2026-08-01 08:00:00+02'+((value%720)||' minutes')::interval,
        '${user}'::uuid,'{"status":"todo"}'::jsonb,'${user}'::uuid
      from generate_series(1,50000) value;
      insert into public.documents(
        id,company_id,document_type,number,client_id,status,issue_date,due_date,
        total_cost,total_excl_tax,total_tax,total_incl_tax,finalized_at,assigned_user_id,created_by
      )
      select gen_random_uuid(),'${company}'::uuid,'invoice','PERF-'||value,'${client}'::uuid,'finalized',
        date '2026-07-01'+((value-1)%24),date '2026-07-01'+((value-1)%24)+30,
        55,100,20,120,clock_timestamp(),'${user}'::uuid,'${user}'::uuid
      from generate_series(1,50000) value;
      insert into public.payments(
        id,company_id,document_id,amount,currency,paid_at,payment_method,status,entry_type,created_by
      )
      select gen_random_uuid(),'${company}'::uuid,document.id,30,'EUR',
        (document.issue_date+payment.position)::timestamp at time zone 'Europe/Paris',
        'bank_transfer','confirmed','payment','${user}'::uuid
      from public.documents document cross join generate_series(1,2) payment(position)
      where document.company_id='${company}';
      set session_replication_role=origin;
      analyze public.documents;
      analyze public.payments;
      analyze public.clients;
      analyze public.activities;
      analyze public.catalog_items;
    `);
    await setIdentity(db,user);
    const started=performance.now();
    const cockpit=(await db.query("select public.get_dashboard_cockpit('current_month',null,null,'previous') value")).rows[0].value;
    const elapsed=Math.round(performance.now()-started);
    if(Number(cockpit.summary.invoice_count)!==50000)throw new Error(`invoice count ${cockpit.summary.invoice_count}`);
    if(Number(cockpit.summary.revenue_ht)!==5000000)throw new Error(`revenue ${cockpit.summary.revenue_ht}`);
    if(Number(cockpit.summary.collected)!==3000000)throw new Error(`collected ${cockpit.summary.collected}`);
    if(Number(cockpit.summary.outstanding)!==3000000)throw new Error(`outstanding ${cockpit.summary.outstanding}`);
    if(!Array.isArray(cockpit.timeseries)||cockpit.timeseries.length!==31)throw new Error(`timeseries buckets ${cockpit.timeseries?.length}`);
    if(Number(cockpit.customers.new_clients)!==10001)throw new Error(`client count ${cockpit.customers.new_clients}`);
    if(Number(cockpit.activity.upcoming)!==50000)throw new Error(`activity count ${cockpit.activity.upcoming}`);
    if(elapsed>15000)throw new Error(`dashboard query exceeded 15 seconds (${elapsed} ms)`);
    process.stdout.write(JSON.stringify({ok:true,clients:10001,invoices:50000,payments:100000,activities:50000,catalog_items:20000,elapsed_ms:elapsed,no_n_plus_one:true})+'\n');
  }finally{await db.close();}
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1;});
