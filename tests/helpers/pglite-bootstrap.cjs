const fs=require('node:fs');
const path=require('node:path');

function loadPGlite(){
  const packageRoot=process.env.PILOZ_PGLITE_ROOT;
  if(!packageRoot)throw new Error('PILOZ_PGLITE_ROOT is required');
  return{
    PGlite:require(path.join(packageRoot,'dist','index.cjs')).PGlite,
    pgcrypto:require(path.join(packageRoot,'dist','contrib','pgcrypto.cjs')).pgcrypto
  };
}

async function setIdentity(db,userId,aal='aal2'){
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.aal',$2,false),set_config('request.jwt.claim.iat',extract(epoch from now())::bigint::text,false),set_config('request.jwt.claim.session_id',$1||'-session',false)",[userId,aal]);
  await db.exec('set role authenticated');
}

async function bootstrap(db){
  const migrationsDir=path.resolve(__dirname,'..','..','supabase','migrations');
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
}

module.exports={loadPGlite,setIdentity,bootstrap};
