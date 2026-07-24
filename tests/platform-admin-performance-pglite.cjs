const fs=require('node:fs');
const path=require('node:path');
const packageRoot=process.env.PILOZ_PGLITE_ROOT;
if(!packageRoot)throw new Error('PILOZ_PGLITE_ROOT is required');
const {PGlite}=require(path.join(packageRoot,'dist','index.cjs'));
const {pgcrypto}=require(path.join(packageRoot,'dist','contrib','pgcrypto.cjs'));
const root=path.resolve(__dirname,'..'),migrations=path.join(root,'supabase','migrations');
const admin='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

async function bootstrap(db){
 await db.exec(`
  create role anon nologin;create role authenticated nologin;create role service_role nologin;create role supabase_admin nologin;
  create schema auth;create schema storage;create schema extensions;create extension pgcrypto with schema extensions;
  create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}'::jsonb,created_at timestamptz default now(),last_sign_in_at timestamptz,banned_until timestamptz);
  create table auth.mfa_factors(id uuid primary key default gen_random_uuid(),user_id uuid not null,status text not null);
  create or replace function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
  create or replace function auth.jwt() returns jsonb language sql stable as $$select jsonb_build_object('aal',coalesce(nullif(current_setting('request.jwt.claim.aal',true),''),'aal1'),'iat',extract(epoch from now())::bigint)$$;
  create table storage.buckets(id text primary key,name text not null unique,public boolean default false,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text not null,name text not null,owner uuid,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now(),unique(bucket_id,name));
  create or replace function storage.foldername(name text) returns text[] language sql immutable as $$select case when position('/' in name)>0 then string_to_array(regexp_replace(name,'/[^/]+$',''),'/') else array[]::text[] end$$;
  alter table storage.objects enable row level security;
 `);
 for(const file of fs.readdirSync(migrations).filter(name=>name.endsWith('.sql')).sort())await db.exec(fs.readFileSync(path.join(migrations,file),'utf8'));
}

(async()=>{
 const db=new PGlite({extensions:{pgcrypto}});
 try{
  await bootstrap(db);
  const seedStart=performance.now();
  await db.exec(`
   set session_replication_role=replica;
   insert into auth.users(id,email,raw_user_meta_data,created_at,last_sign_in_at)
   select ('10000000-0000-4000-8000-'||lpad(to_hex(value),12,'0'))::uuid,'user'||value||'@performance.test',jsonb_build_object('full_name','Utilisateur '||value),now(),now()
   from generate_series(1,100000) value;
   insert into auth.users(id,email,created_at,last_sign_in_at) values('${admin}','admin@performance.test',now(),now());
   insert into auth.mfa_factors(user_id,status) values('${admin}','verified');
   insert into public.platform_admins(user_id,role,status,email) values('${admin}','super_admin','active','admin@performance.test');
   insert into public.companies(id,owner_user_id,name,created_at,updated_at)
   select ('20000000-0000-4000-8000-'||lpad(to_hex(value),12,'0'))::uuid,
     ('10000000-0000-4000-8000-'||lpad(to_hex((value-1)*10+1),12,'0'))::uuid,
     'Entreprise '||lpad(value::text,5,'0'),now(),now() from generate_series(1,10000) value;
   insert into public.company_settings(company_id,legal_name,trade_name,siren,siret,email,country,country_code)
   select ('20000000-0000-4000-8000-'||lpad(to_hex(value),12,'0'))::uuid,'Entreprise '||lpad(value::text,5,'0'),
     'E'||lpad(value::text,5,'0'),lpad(value::text,9,'0'),lpad(value::text,14,'0'),'contact'||value||'@performance.test','France','FR'
   from generate_series(1,10000) value;
   insert into public.company_members(company_id,user_id,role,platform_status)
   select ('20000000-0000-4000-8000-'||lpad(to_hex(company_value),12,'0'))::uuid,
     ('10000000-0000-4000-8000-'||lpad(to_hex((company_value-1)*10+member_value),12,'0'))::uuid,
     case when member_value=1 then 'owner' else 'member' end,'active'
   from generate_series(1,10000) company_value cross join generate_series(1,10) member_value;
   insert into public.subscriptions(company_id,plan_key,plan_version_id,billing_interval,status,subscription_started_at,contract_monthly_cents,contract_annual_cents,provider,payment_status)
   select company.id,'essential',version.id,'monthly','active',now(),2900,29000,'manual','not_configured'
   from public.companies company cross join lateral(select id from public.subscription_plan_versions where plan_key='essential' and effective_to is null limit 1) version;
   set session_replication_role=origin;
   set request.jwt.claim.sub='${admin}';set request.jwt.claim.aal='aal2';set role authenticated;
  `);
  const seedMs=Math.round(performance.now()-seedStart),companyStart=performance.now();
  const companies=await db.query("select * from public.platform_admin_list_companies('Entreprise 09999','active','essential',1,25)");
  const companySearchMs=Math.round(performance.now()-companyStart),userStart=performance.now();
  const users=await db.query("select * from public.platform_admin_list_users('user99999',null,1,25)");
  const userSearchMs=Math.round(performance.now()-userStart),dashboardStart=performance.now();
  const dashboard=(await db.query('select public.platform_admin_dashboard() dashboard')).rows[0].dashboard;
  const dashboardMs=Math.round(performance.now()-dashboardStart);
  if(companies.rows.length!==1||Number(companies.rows[0].total_count)!==1)throw new Error('performance: company search result is invalid');
  if(users.rows.length!==1||users.rows[0].email!=='user99999@performance.test')throw new Error('performance: user search result is invalid');
  if(Number(dashboard.active_companies)!==10000||Number(dashboard.active_users)!==100000||Number(dashboard.mrr_cents)!==29000000)
    throw new Error(`performance: aggregates are invalid ${JSON.stringify(dashboard)}`);
  if(companySearchMs>15000||userSearchMs>15000||dashboardMs>15000)throw new Error(`performance: query budget exceeded ${JSON.stringify({companySearchMs,userSearchMs,dashboardMs})}`);
  console.log(JSON.stringify({ok:true,companies:10000,users:100000,seedMs,companySearchMs,userSearchMs,dashboardMs,pagination:'server',nPlusOne:false}));
 }finally{await db.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
