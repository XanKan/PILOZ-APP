const fs=require('node:fs');
const path=require('node:path');

const packageRoot=process.env.PILOZ_PGLITE_ROOT;
if(!packageRoot)throw new Error('PILOZ_PGLITE_ROOT is required');
const {PGlite}=require(path.join(packageRoot,'dist','index.cjs'));
const {pgcrypto}=require(path.join(packageRoot,'dist','contrib','pgcrypto.cjs'));

const repoRoot=path.resolve(__dirname,'..');
const migrationsDir=path.join(repoRoot,'supabase','migrations');
const superAdmin='11111111-1111-4111-8111-111111111111';
const readOnlyAdmin='22222222-2222-4222-8222-222222222222';
const customer='33333333-3333-4333-8333-333333333333';
const company='44444444-4444-4444-8444-444444444444';
const secondOwner='55555555-5555-4555-8555-555555555555';
const secondMember='66666666-6666-4666-8666-666666666666';

async function setIdentity(db,userId,aal='aal2'){
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.aal',$2,false),set_config('request.jwt.claim.iat',extract(epoch from now())::bigint::text,false),set_config('request.jwt.claim.session_id',$1||'-session',false)",[userId,aal]);
  await db.exec('set role authenticated');
  if(aal==='aal2'&&(userId===superAdmin||userId===readOnlyAdmin))await db.query("select public.platform_admin_register_session('PGlite test session')");
}

async function bootstrap(db){
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    create role supabase_admin nologin;
    create schema auth;
    create schema storage;
    create schema extensions;
    create extension pgcrypto with schema extensions;
    create table auth.users(
      id uuid primary key,email text,raw_user_meta_data jsonb default '{}'::jsonb,
      created_at timestamptz default now(),last_sign_in_at timestamptz,banned_until timestamptz
    );
    create table auth.mfa_factors(id uuid primary key default gen_random_uuid(),user_id uuid not null,status text not null);
    create or replace function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create or replace function auth.jwt() returns jsonb language sql stable as $$
      select jsonb_build_object(
        'aal',coalesce(nullif(current_setting('request.jwt.claim.aal',true),''),'aal1'),
        'iat',coalesce(nullif(current_setting('request.jwt.claim.iat',true),'')::bigint,extract(epoch from now())::bigint),
        'session_id',nullif(current_setting('request.jwt.claim.session_id',true),'')
      )
    $$;
    create table storage.buckets(
      id text primary key,name text not null unique,public boolean default false,
      file_size_limit bigint,allowed_mime_types text[]
    );
    create table storage.objects(
      id uuid primary key default gen_random_uuid(),bucket_id text not null,name text not null,
      owner uuid,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now(),
      unique(bucket_id,name)
    );
    create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
      select case when position('/' in name)>0 then string_to_array(regexp_replace(name,'/[^/]+$',''),'/') else array[]::text[] end
    $$;
    alter table storage.objects enable row level security;
  `);
  for(const file of fs.readdirSync(migrationsDir).filter(name=>name.endsWith('.sql')).sort()){
    try{await db.exec(fs.readFileSync(path.join(migrationsDir,file),'utf8'));}
    catch(error){error.message=`Migration ${file}: ${error.message}`;throw error;}
  }
  await db.exec(`
    insert into auth.users(id,email,raw_user_meta_data,last_sign_in_at) values
      ('${superAdmin}','admin@piloz.fr','{"first_name":"Super","last_name":"Admin"}',now()),
      ('${readOnlyAdmin}','lecture@piloz.fr','{"first_name":"Lecture"}',now()),
      ('${customer}','client@piloz.fr','{"full_name":"Client Piloz"}',now()),
      ('${secondOwner}','proprietaire2@piloz.fr','{"full_name":"Deuxième Propriétaire"}',now()),
      ('${secondMember}','membre2@piloz.fr','{"full_name":"Deuxième Membre"}',now());
    insert into auth.mfa_factors(user_id,status) values('${superAdmin}','verified'),('${readOnlyAdmin}','verified');
    insert into public.platform_admins(user_id,role,status,first_name,last_name,email) values
      ('${superAdmin}','super_admin','active','Super','Admin','admin@piloz.fr'),
      ('${readOnlyAdmin}','read_only_admin','active','Lecture',null,'lecture@piloz.fr');
    insert into public.companies(id,owner_user_id,name) values('${company}','${customer}','Entreprise contrôlée');
    insert into public.company_members(company_id,user_id,role) values('${company}','${customer}','owner');
    insert into public.company_settings(company_id,legal_name,trade_name,email)
      values('${company}','Entreprise contrôlée SAS','Entreprise contrôlée','contact@entreprise.test')
      on conflict(company_id) do update set legal_name=excluded.legal_name,trade_name=excluded.trade_name,email=excluded.email;
    update public.subscriptions subscription set status='active',billing_interval='monthly',
      plan_version_id=version.id,contract_monthly_cents=version.price_monthly_cents,
      contract_annual_cents=version.price_annual_cents,updated_at=now()
    from public.subscription_plan_versions version
    where subscription.company_id='${company}' and version.plan_key='essential' and version.effective_to is null;
  `);
}

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec(`
      select mode,activation_status,application_version,schema_version,signing_status,updated_at
      from public.company_fiscal_configurations limit 0;
      select id,anomaly_type,severity,source,detected_at
      from public.compliance_anomalies limit 0;
    `);

    await setIdentity(db,customer,'aal2');
    const customerAdmin=await db.query("select public.is_platform_admin('companies.read',true) allowed");
    if(customerAdmin.rows[0].allowed)throw new Error('security: a customer was accepted as platform administrator');
    const customerDashboard=await db.query('select public.platform_admin_dashboard()').then(()=>null,error=>error);
    if(!customerDashboard||!/platform_admin_access_denied/.test(customerDashboard.message))throw new Error('security: customer dashboard access was not denied');

    await setIdentity(db,superAdmin,'aal1');
    const aal1=await db.query("select public.is_platform_admin('companies.read',true) allowed");
    if(aal1.rows[0].allowed)throw new Error('security: MFA AAL2 was not required');

    await setIdentity(db,superAdmin,'aal2');
    const context=(await db.query('select public.platform_admin_context() context')).rows[0].context;
    if(context.role!=='super_admin'||context.aal!=='aal2'||!context.permissions.includes('subscriptions.write'))
      throw new Error(`security: invalid super-admin context ${JSON.stringify(context)}`);
    await db.query("select set_config('request.jwt.claim.iat',(extract(epoch from now())::bigint-86400)::text,false)");
    const activeMfaSession=await db.query('select public.platform_admin_recent_auth(300) allowed');
    if(!activeMfaSession.rows[0].allowed)throw new Error('session: active MFA session incorrectly required repeated credentials');
    const dashboard=(await db.query('select public.platform_admin_dashboard() dashboard')).rows[0].dashboard;
    if(Number(dashboard.active_companies)!==1||Number(dashboard.mrr_cents)!==2900||Number(dashboard.arr_cents)!==34800)
      throw new Error(`revenue: invalid contract metrics ${JSON.stringify(dashboard)}`);
    const companies=await db.query("select * from public.platform_admin_list_companies('contrôlée',null,null,1,25)");
    if(companies.rows.length!==1||companies.rows[0].company_id!==company)throw new Error('companies: secure search failed');
    const users=await db.query('select * from public.platform_admin_list_users(null,$1,1,25)',[company]);
    if(users.rows.length!==1||users.rows[0].account_status!=='active'||users.rows[0].email!=='client@piloz.fr')
      throw new Error(`users: real account status is invalid ${JSON.stringify(users.rows)}`);

    await setIdentity(db,readOnlyAdmin,'aal2');
    const readOnly=await db.query("select public.is_platform_admin('companies.read',true) can_read,public.is_platform_admin('subscriptions.write',true) can_write");
    if(!readOnly.rows[0].can_read||readOnly.rows[0].can_write)throw new Error('permissions: read-only role is not isolated');
    const forbiddenChange=await db.query("select public.platform_admin_change_subscription($1,(select id from public.subscription_plan_versions where plan_key='business' and effective_to is null limit 1),'monthly','immediate',null,null,null,'Interdit',null)",[company]).then(()=>null,error=>error);
    if(!forbiddenChange||!/recent_reauthentication_required/.test(forbiddenChange.message))throw new Error('permissions: read-only subscription mutation was accepted');

    await setIdentity(db,superAdmin,'aal2');
    const changed=(await db.query("select * from public.platform_admin_change_subscription($1,(select id from public.subscription_plan_versions where plan_key='business' and effective_to is null limit 1),'monthly','immediate',null,null,null,'Passage au plan Business','Contrat validé')",[company])).rows[0];
    if(changed.plan_key!=='business'||Number(changed.contract_monthly_cents)!==9900)throw new Error(`subscription: contract change failed ${JSON.stringify(changed)}`);
    const afterChange=(await db.query('select public.platform_admin_dashboard() dashboard')).rows[0].dashboard;
    if(Number(afterChange.mrr_cents)!==9900)throw new Error(`revenue: MRR was not updated ${JSON.stringify(afterChange)}`);
    const changeAudit=await db.query("select event_hash,previous_hash from public.platform_admin_audit_events where action='subscription.change'");
    if(changeAudit.rows.length!==1||!changeAudit.rows[0].event_hash)throw new Error(`audit: subscription change is not chained ${JSON.stringify(changeAudit.rows)}`);
    const auditMutation=await db.query("update public.platform_admin_audit_events set reason='altéré'").then(()=>null,error=>error);
    if(!auditMutation)throw new Error('audit: immutable log could be modified');

    const proVersion=(await db.query("select id from public.subscription_plan_versions where plan_key='pro' and effective_to is null limit 1")).rows[0].id;
    const created=(await db.query("select * from public.platform_admin_create_company($1,$2::jsonb,$3::jsonb,'Ouverture validée')",[
      secondOwner,JSON.stringify({legal_name:'Nouvelle Entreprise SAS',trade_name:'Nouvelle Entreprise',siren:'123123123',siret:'12312312300015',email:'nouvelle@entreprise.test',country:'France',country_code:'FR',currency:'EUR',language:'fr',owner_first_name:'Nouvelle',owner_last_name:'Propriétaire',admin_tags:['test']}),
      JSON.stringify({plan_version_id:proVersion,billing_interval:'annual',status:'trialing',trial_days:21,max_users:8,feature_overrides:{api_access:true}})
    ])).rows[0];
    if(!created.id)throw new Error('companies: secure creation failed');
    const createdSubscription=(await db.query('select plan_key,billing_interval,status,trial_ends_at from public.subscriptions where company_id=$1',[created.id])).rows[0];
    if(createdSubscription.plan_key!=='pro'||createdSubscription.billing_interval!=='annual'||createdSubscription.status!=='trialing')
      throw new Error(`companies: subscription provisioning failed ${JSON.stringify(createdSubscription)}`);
    const updated=(await db.query("select * from public.platform_admin_update_company($1,$2::jsonb,'Coordonnées vérifiées')",[created.id,JSON.stringify({trade_name:'Nouvelle Entreprise France',phone:'+33102030405',admin_tags:['test','prioritaire']})])).rows[0];
    if(updated.name!=='Nouvelle Entreprise France')throw new Error('companies: update failed');
    await db.query("select public.platform_admin_manage_company_user($1,$2,'member','attach','Invitation interne')",[created.id,secondMember]);
    await db.query("select public.platform_admin_manage_company_user($1,$2,'member','suspend','Contrôle temporaire')",[created.id,secondMember]);
    const memberSuspended=await db.query("select account_status from public.platform_admin_list_users('membre2',null,1,25)");
    if(memberSuspended.rows[0].account_status!=='suspended')throw new Error('users: membership suspension failed');
    await db.query("select public.platform_admin_manage_company_user($1,$2,'member','reactivate','Contrôle terminé')",[created.id,secondMember]);
    const feature=(await db.query("select * from public.platform_admin_set_feature_override($1,'advanced_dashboard',true,now()+interval '30 days','Essai encadré')",[created.id])).rows[0];
    if(!feature.enabled)throw new Error('features: company override failed');
    const activated=(await db.query("select * from public.platform_admin_manage_subscription($1,'activate_manual','{}'::jsonb,'Contrat manuel signé')",[created.id])).rows[0];
    if(activated.status!=='active'||activated.provider!=='manual')throw new Error('subscriptions: manual activation failed');
    const exported=(await db.query("select public.platform_admin_export_company($1,'Demande de contrôle') payload",[created.id])).rows[0].payload;
    if(exported.company.id!==created.id||Number(exported.record_counts.documents)!==0)throw new Error('privacy: company export failed');
    const newPlan=(await db.query("select * from public.platform_admin_create_plan_version('pro',$1::jsonb,'Nouvelle grille future')",[JSON.stringify({name:'Pro',price_monthly_cents:6100,price_annual_cents:61000,max_users:6,features:['crm','quotes','invoices'],limits:{api_calls:1000},effective_from:'2026-08-01T00:00:00Z'})])).rows[0];
    if(Number(newPlan.version)!==2||Number(newPlan.price_monthly_cents)!==6100)throw new Error('plans: immutable version creation failed');
    const profile=(await db.query("select * from public.platform_admin_update_profile('{\"timezone\":\"Europe/Paris\",\"language\":\"fr\"}'::jsonb)")).rows[0];
    if(profile.language!=='fr')throw new Error('admin: profile update failed');
    const registeredSession=(await db.query("select public.platform_admin_register_session('PGlite security test') id")).rows[0].id;
    if(!registeredSession)throw new Error('admin: session registration failed');

    const support=(await db.query("select * from public.platform_admin_start_support_session($1,'Diagnostic demandé','read_only')",[company])).rows[0];
    if(!support.id||support.mode!=='read_only')throw new Error('support: session was not created');
    const ended=(await db.query('select * from public.platform_admin_end_support_session($1)',[support.id])).rows[0];
    if(!ended.ended_at)throw new Error('support: session was not closed');

    const suspended=(await db.query("select * from public.platform_admin_set_company_suspension($1,true,'full','Impayé confirmé')",[company])).rows[0];
    if(suspended.platform_status!=='suspended'||suspended.suspension_level!=='full')throw new Error('suspension: company was not suspended');
    await setIdentity(db,customer,'aal2');
    const blocked=await db.query('select public.is_company_member($1) member',[company]);
    if(blocked.rows[0].member)throw new Error('suspension: customer retained application access');

    await setIdentity(db,superAdmin,'aal2');
    const reactivated=(await db.query("select * from public.platform_admin_set_company_suspension($1,false,'full','Paiement régularisé')",[company])).rows[0];
    if(reactivated.platform_status!=='active')throw new Error('suspension: company was not reactivated');
    await setIdentity(db,customer,'aal2');
    const restored=await db.query('select public.is_company_member($1) member',[company]);
    if(!restored.rows[0].member)throw new Error('suspension: customer access was not restored');

    await db.exec('reset role');
    await db.query("update public.platform_admins set status='suspended' where user_id=$1",[readOnlyAdmin]);
    await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.aal','aal2',false),set_config('request.jwt.claim.session_id',$1||'-session',false)",[readOnlyAdmin]);
    await db.exec('set role authenticated');
    const suspendedAdmin=await db.query('select public.platform_admin_context()').then(()=>null,error=>error);
    if(!suspendedAdmin||!/platform_admin_access_denied/.test(suspendedAdmin.message))throw new Error('security: suspended administrator retained access');
    await db.exec('reset role');
    await db.query("update public.platform_admin_sessions set expires_at=now()-interval '1 minute' where admin_id=(select id from public.platform_admins where user_id=$1)",[superAdmin]);
    await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.aal','aal2',false),set_config('request.jwt.claim.session_id',$1||'-session',false)",[superAdmin]);
    await db.exec('set role authenticated');
    const expiredSession=await db.query('select public.platform_admin_validate_and_touch_session() active');
    if(expiredSession.rows[0].active)throw new Error('security: expired administrator session was accepted');

    await db.exec('reset role');
    const audit=await db.query('select count(*)::int count,count(event_hash)::int hashed from public.platform_admin_audit_events');
    if(Number(audit.rows[0].count)<15||audit.rows[0].count!==audit.rows[0].hashed)throw new Error(`audit: incomplete platform trail ${JSON.stringify(audit.rows[0])}`);
    console.log(JSON.stringify({ok:true,roleIsolation:true,mfaRequired:true,activeSessionNoRepeatedCredentials:true,adminSuspension:true,sessionExpiry:true,mrrCents:Number(afterChange.mrr_cents),auditEvents:Number(audit.rows[0].count),companyCrud:true,userLifecycle:true,subscriptionLifecycle:true,planVersioning:true,export:true,supportClosed:true,suspensionEnforced:true,companyDetailSchema:true}));
  }finally{
    await db.close();
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
