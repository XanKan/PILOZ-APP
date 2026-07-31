const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

const owner='11111111-1111-4111-8111-111111111111';
const otherOwner='22222222-2222-4222-8222-222222222222';
const reader='33333333-3333-4333-8333-333333333333';
const sales='44444444-4444-4444-8444-444444444444';
const companyA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const companyB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const clientA='caaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const clientB='cbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const invoiceA='daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const creditA='daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
const previousA='daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3';
const quoteA='daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4';
const invoiceB='dbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
const paymentA='eaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const warehouseA='faaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const itemA='faaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';

function closeTo(actual,expected,label){if(Math.abs(Number(actual)-expected)>.001)throw new Error(`${label}: expected ${expected}, got ${actual}`);}

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    const dashboardFunctions=(await db.query(`
      select proname,prosecdef,coalesce(array_to_string(proconfig,','),'') config
      from pg_proc join pg_namespace namespace on namespace.oid=pronamespace
      where namespace.nspname='public' and (
        proname like 'get_dashboard_%' or proname in(
          'get_revenue_timeseries','get_cash_collection_forecast','get_sales_funnel_summary',
          'get_receivables_dashboard_summary','get_customer_performance_summary',
          'get_catalog_performance_summary','get_stock_alert_summary','get_user_activity_summary',
          'save_dashboard_preferences','_dashboard_request_context','_dashboard_period_bounds'
        )
      )
    `)).rows;
    if(!dashboardFunctions.length||dashboardFunctions.some(row=>!row.prosecdef||!String(row.config).includes('search_path=public, pg_temp')))
      throw new Error('dashboard SECURITY DEFINER search_path is not fixed');
    await db.exec(`
      insert into auth.users(id,email,raw_user_meta_data) values
        ('${owner}','owner@a.test','{"first_name":"Alice"}'),
        ('${otherOwner}','owner@b.test','{"first_name":"Bob"}'),
        ('${reader}','reader@a.test','{"first_name":"Rita"}'),
        ('${sales}','sales@a.test','{"first_name":"Sam"}');
      insert into public.companies(id,owner_user_id,name) values
        ('${companyA}','${owner}','Entreprise A'),('${companyB}','${otherOwner}','Entreprise B');
      insert into public.company_members(company_id,user_id,role) values
        ('${companyA}','${owner}','owner'),('${companyA}','${reader}','read_only'),
        ('${companyA}','${sales}','sales'),('${companyB}','${otherOwner}','owner');
      insert into public.user_preferences(user_id,company_id,first_name) values
        ('${owner}','${companyA}','Alice'),('${reader}','${companyA}','Rita'),
        ('${sales}','${companyA}','Sam'),('${otherOwner}','${companyB}','Bob');
      insert into public.company_settings(company_id,legal_name,currency,siret,email,address_line1,postal_code,city,country_code,onboarding_completed_at) values
        ('${companyA}','Entreprise A','EUR','12345678900011','contact@a.test','1 rue A','75001','Paris','FR',now()),
        ('${companyB}','Entreprise B','EUR','12345678900022','contact@b.test','2 rue B','69001','Lyon','FR',now())
        on conflict(company_id) do update set legal_name=excluded.legal_name,currency=excluded.currency,
          siret=excluded.siret,email=excluded.email,address_line1=excluded.address_line1,postal_code=excluded.postal_code,
          city=excluded.city,country_code=excluded.country_code,onboarding_completed_at=excluded.onboarding_completed_at;
      insert into public.clients(id,company_id,kind,legal_name,active,created_by) values
        ('${clientA}','${companyA}','company','Client A',true,'${owner}'),
        ('${clientB}','${companyB}','company','Client B',true,'${otherOwner}');
      insert into public.company_feature_overrides(company_id,feature_key,enabled,reason)
        values('${companyA}','inventory',true,'Dashboard integration test');
      insert into public.warehouses(id,company_id,code,name,active,created_by)
        values('${warehouseA}','${companyA}','MAIN','Entrepôt principal',true,'${owner}');
      insert into public.catalog_items(id,company_id,item_type,reference,name,unit,cost_price,sale_price,stock_managed,minimum_stock,reorder_point,active,created_by)
        values('${itemA}','${companyA}','product','ITEM-A','Article A','unité',10,0,true,5,5,true,'${owner}');
      set session_replication_role=replica;
      insert into public.documents(
        id,company_id,document_type,number,client_id,status,issue_date,due_date,validity_date,
        total_cost,total_excl_tax,total_tax,total_incl_tax,finalized_at,assigned_user_id,created_by
      ) values
        ('${invoiceA}','${companyA}','invoice','FAC-A-1','${clientA}','finalized','2026-07-05','2026-07-20',null,600,1000,200,1200,'2026-07-05T10:00:00Z','${owner}','${owner}'),
        ('${creditA}','${companyA}','credit_note','AV-A-1','${clientA}','finalized','2026-07-10','2026-07-10',null,50,100,20,120,'2026-07-10T10:00:00Z','${owner}','${owner}'),
        ('${previousA}','${companyA}','invoice','FAC-A-0','${clientA}','finalized','2026-06-05','2026-06-20',null,300,500,100,600,'2026-06-05T10:00:00Z','${owner}','${owner}'),
        ('${quoteA}','${companyA}','quote','DEV-A-1','${clientA}','accepted','2026-07-12',null,'2026-07-31',0,700,140,840,null,'${owner}','${owner}'),
        ('${invoiceB}','${companyB}','invoice','FAC-B-1','${clientB}','finalized','2026-07-05','2026-07-20',null,100,9000,1800,10800,'2026-07-05T10:00:00Z','${otherOwner}','${otherOwner}');
      update public.documents set source_document_id='${invoiceA}' where id='${creditA}';
      insert into public.payments(id,company_id,document_id,amount,currency,paid_at,payment_method,status,entry_type,created_by) values
        ('${paymentA}','${companyA}','${invoiceA}',600,'EUR','2026-07-15T10:00:00Z','bank_transfer','confirmed','payment','${owner}'),
        ('eaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','${companyA}','${invoiceA}',-100,'EUR','2026-07-16T10:00:00Z','bank_transfer','confirmed','correction','${owner}'),
        ('ebbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1','${companyB}','${invoiceB}',10800,'EUR','2026-07-15T10:00:00Z','bank_transfer','confirmed','payment','${otherOwner}');
      update public.payments set reverses_payment_id='${paymentA}',correction_reason='Erreur de saisie'
        where id='eaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
      insert into public.payment_schedules(company_id,document_id,due_date,amount,paid_amount,status,label,created_by)
        values('${companyA}','${previousA}','2026-07-28',600,100,'partial','Plan 1','${owner}');
      insert into public.activities(company_id,activity_type,subject,scheduled_at,assigned_user_id,created_by,metadata)
        values('${companyA}','task','Relancer Client A','2026-07-23T09:00:00Z','${owner}','${owner}','{"priority":"high","status":"todo"}');
      insert into public.notifications(company_id,user_id,notification_type,title,message,metadata,created_by)
        values('${companyA}','${owner}','payment_overdue','Paiement en retard','Facture FAC-A-1','{"severity":"critical"}','${owner}');
      set session_replication_role=origin;
    `);

    await setIdentity(db,owner);
    await db.exec('reset role');
    const granularities=(await db.query(`
      select
        (select granularity from public._dashboard_period_bounds('custom','2026-07-01','2026-07-31','none')) short,
        (select granularity from public._dashboard_period_bounds('custom','2026-01-01','2026-04-30','none')) medium,
        (select granularity from public._dashboard_period_bounds('custom','2026-01-01','2026-12-31','none')) annual,
        (select granularity from public._dashboard_period_bounds('custom','2022-01-01','2026-12-31','none')) long
    `)).rows[0];
    if(granularities.short!=='day'||granularities.medium!=='week'||granularities.annual!=='month'||granularities.long!=='year')
      throw new Error(`invalid automatic granularities: ${JSON.stringify(granularities)}`);
    await setIdentity(db,owner);
    const cockpit=(await db.query("select public.get_dashboard_cockpit('custom','2026-07-01','2026-07-31','previous') value")).rows[0].value;
    if(cockpit.first_name!=='Alice')throw new Error(`profile: ${cockpit.first_name}`);
    closeTo(cockpit.summary.revenue_ht,900,'revenue net of credit');
    closeTo(cockpit.summary.collected,500,'collections net of reversal');
    closeTo(cockpit.summary.outstanding,1180,'outstanding net of payment and credit, including prior open invoices');
    closeTo(cockpit.summary.gross_margin,350,'gross margin');
    closeTo(cockpit.summary.previous_revenue_ht,500,'previous revenue');
    closeTo(cockpit.summary.revenue_change_percent,80,'revenue evolution');
    closeTo(cockpit.summary.conversion_rate,100,'quote conversion');
    if(cockpit.summary.scope!=='company'||cockpit.summary.permissions.margin!==true
      ||cockpit.summary.permissions.sales_documents!==true||cockpit.summary.permissions.payments!==true
      ||cockpit.summary.permissions.customers!==true||cockpit.summary.permissions.activities!==true)throw new Error('owner permissions invalid');
    if(!Array.isArray(cockpit.timeseries)||!cockpit.timeseries.length)throw new Error('timeseries unavailable');
    closeTo(cockpit.timeseries.reduce((sum,row)=>sum+Number(row.credits||0),0),100,'timeseries credit notes');
    closeTo(cockpit.timeseries.reduce((sum,row)=>sum+Number(row.corrections||0),0),100,'timeseries payment corrections');
    if(cockpit.timeseries.reduce((sum,row)=>sum+Number(row.invoice_count||0),0)!==1)throw new Error('timeseries invoice count invalid');
    const topClient=cockpit.customers.top_clients.find(row=>row.id===clientA);
    closeTo(topClient?.revenue,900,'customer net revenue');
    closeTo(topClient?.collected,500,'customer net collections');
    if(!cockpit.priority_actions.some(row=>row.kind==='accepted_quote'&&row.can_write===true))throw new Error('accepted quote action unavailable');
    if(!String(cockpit.forecast.source_label||'').includes('plans de reglement')||!cockpit.forecast.buckets.length)throw new Error('payment schedule forecast unavailable');
    if(cockpit.stock.enabled!==true||Number(cockpit.stock.count)!==1||cockpit.stock.alerts[0]?.id!==itemA)throw new Error('conditional stock summary invalid');
    if(Number(cockpit.catalog.never_sold)!==1||Number(cockpit.catalog.missing_price)!==1)throw new Error('catalog alerts invalid');
    if(cockpit.activity.notifications[0]?.body!=='Facture FAC-A-1'||cockpit.activity.notifications[0]?.severity!=='critical')throw new Error('notification summary invalid');
    if(cockpit.recent_documents.some(row=>String(row.number||'').startsWith('FAC-B')))throw new Error('cross-company document leak');

    const saved=(await db.query("select public.save_dashboard_preferences(2,'[\"agenda\",\"receivables\"]','[\"receivables\",\"agenda\"]','{\"receivables\":\"wide\"}','[\"revenue_ht\",\"collected\",\"pipeline_weighted\"]','{\"preset\":\"last_30_days\",\"comparison\":\"year\"}') value")).rows[0].value;
    if(saved.block_order.join('|')!=='receivables|agenda'||saved.period_config.preset!=='last_30_days'||!saved.selected_metrics.includes('pipeline_weighted'))throw new Error('preferences not persisted with pipeline widget');
    const tooManyMetrics=await db.query("select public.save_dashboard_preferences(2,'[]','[]','{}','[\"revenue_ht\",\"collected\",\"outstanding\",\"gross_margin\",\"new_clients\"]','{}')").then(()=>null,error=>error);
    if(!tooManyMetrics)throw new Error('dashboard metric limit not enforced');

    await setIdentity(db,reader);
    const readOnly=(await db.query("select public.get_dashboard_cockpit('custom','2026-07-01','2026-07-31','previous') value")).rows[0].value;
    if(readOnly.summary.permissions.write!==false||readOnly.summary.permissions.margin!==false
      ||readOnly.summary.permissions.sales_documents!==false||readOnly.summary.permissions.payments!==false
      ||readOnly.summary.permissions.customers!==false||readOnly.summary.permissions.activities!==false)throw new Error('read-only permissions exposed sensitive actions');
    if(readOnly.summary.gross_margin!==null||readOnly.timeseries.some(row=>row.margin!==null))throw new Error('margin leaked to read-only user');
    if(readOnly.preferences.block_order.length)throw new Error('user preference isolation failed');

    await setIdentity(db,sales);
    const salesCockpit=(await db.query("select public.get_dashboard_cockpit('custom','2026-07-01','2026-07-31','previous') value")).rows[0].value;
    if(salesCockpit.summary.scope!=='personal'||Number(salesCockpit.summary.revenue_ht)!==0)throw new Error('sales personal scope failed');

    await setIdentity(db,otherOwner);
    const other=(await db.query("select public.get_dashboard_cockpit('custom','2026-07-01','2026-07-31','previous') value")).rows[0].value;
    closeTo(other.summary.revenue_ht,9000,'company B revenue');
    if(other.preferences.block_order.length)throw new Error('company preference isolation failed');

    await db.exec('reset role');
    await db.query("select set_config('request.jwt.claim.sub','',false)");
    await db.exec('set role anon');
    const anonymousError=await db.query("select public.get_dashboard_cockpit('custom','2026-07-01','2026-07-31','previous')").then(()=>null,error=>error);
    if(!anonymousError)throw new Error('anonymous dashboard access was accepted');

    process.stdout.write(JSON.stringify({ok:true,revenue:cockpit.summary.revenue_ht,collected:cockpit.summary.collected,outstanding:cockpit.summary.outstanding,margin:cockpit.summary.gross_margin,rls:true,permissions:true,preferences:true})+'\n');
  }finally{await db.close();}
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1;});
