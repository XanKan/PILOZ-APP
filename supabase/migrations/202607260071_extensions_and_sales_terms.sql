begin;

-- Connections are owned by one collaborator.  Browser-readable rows contain
-- metadata only; encrypted OAuth/IMAP secrets live in a service-role table.
create table if not exists public.external_connections(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check(provider in('google_calendar','microsoft_calendar','gmail','outlook_mail','imap_smtp')),
  connection_scope text not null default 'personal' check(connection_scope in('personal','shared','company')),
  shared_label text,
  account_email text,
  display_name text,
  status text not null default 'pending' check(status in('pending','connected','reauthorization_required','error','disconnected')),
  consent_scope text[] not null default '{}',
  settings jsonb not null default '{}'::jsonb,
  last_successful_sync_at timestamptz,
  last_attempt_at timestamptz,
  last_error_code text,
  disconnected_at timestamptz,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,user_id,provider)
);

create table if not exists public.external_connection_secrets(
  connection_id uuid primary key references public.external_connections(id) on delete cascade,
  ciphertext text not null,
  initialization_vector text not null,
  key_version text not null,
  expires_at timestamptz,
  refreshable boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.external_oauth_states(
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  state_hash text not null unique check(state_hash ~ '^[a-f0-9]{64}$'),
  verifier_ciphertext text not null,
  verifier_iv text not null,
  return_url text not null,
  expires_at timestamptz not null default (now()+interval '10 minutes'),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.external_sync_states(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  resource_type text not null check(resource_type in('calendar','mail')),
  resource_id text not null default 'primary',
  cursor_ciphertext text,
  cursor_iv text,
  full_sync_required boolean not null default true,
  webhook_channel_id text,
  webhook_expires_at timestamptz,
  last_successful_sync_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(connection_id,resource_type,resource_id)
);

create table if not exists public.external_sync_jobs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  job_type text not null,
  idempotency_key text not null,
  status text not null default 'queued' check(status in('queued','running','succeeded','retry','dead_letter','canceled')),
  attempt_count integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,
  last_error_code text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  unique(connection_id,idempotency_key)
);

create table if not exists public.external_event_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  activity_id uuid references public.activities(id) on delete cascade,
  external_calendar_id text not null,
  external_event_id text not null,
  external_version text,
  piloz_version timestamptz,
  privacy text not null default 'normal' check(privacy in('normal','private')),
  deleted_at timestamptz,
  last_synced_at timestamptz not null default now(),
  unique(connection_id,external_calendar_id,external_event_id)
);

create table if not exists public.external_mail_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.external_connections(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  opportunity_id uuid references public.opportunities(id) on delete set null,
  document_id uuid references public.documents(id) on delete set null,
  external_message_id text,
  direction text not null check(direction in('outbound','inbound')),
  subject text,
  recipients text[] not null default '{}',
  sent_at timestamptz,
  status text not null default 'recorded' check(status in('recorded','queued','sent','delivered','failed')),
  error_code text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(connection_id,external_message_id)
);

-- Versioned sales terms.  A final document freezes a version and never reads
-- the mutable assignment again.
create table if not exists public.sales_terms(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 160),
  status text not null default 'active' check(status in('active','archived')),
  current_version integer not null default 1 check(current_version>0),
  created_by uuid not null default auth.uid(),
  updated_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,name)
);

create table if not exists public.sales_terms_versions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sales_terms_id uuid not null references public.sales_terms(id) on delete restrict,
  version integer not null check(version>0),
  source_type text not null check(source_type in('manual','pdf')),
  body text,
  pdf_storage_path text,
  pdf_sha256 text,
  mime_type text,
  file_size_bytes bigint,
  change_comment text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  check((source_type='manual' and nullif(trim(body),'') is not null and length(body)<=50000 and pdf_storage_path is null)
     or (source_type='pdf' and pdf_storage_path is not null and mime_type='application/pdf' and file_size_bytes between 1 and 10485760)),
  unique(sales_terms_id,version)
);

create table if not exists public.sales_terms_assignments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sales_terms_id uuid not null references public.sales_terms(id) on delete restrict,
  client_id uuid references public.clients(id) on delete cascade,
  document_type text check(document_type in('quote','invoice','credit_note','sales_order','purchase_order')),
  is_default boolean not null default false,
  priority integer not null default 0,
  active boolean not null default true,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  check(client_id is not null or document_type is not null),
  unique(company_id,client_id,document_type)
);

create table if not exists public.document_sales_terms_snapshots(
  document_id uuid primary key references public.documents(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  sales_terms_id uuid references public.sales_terms(id) on delete restrict,
  sales_terms_version_id uuid references public.sales_terms_versions(id) on delete restrict,
  source_type text check(source_type in('manual','pdf')),
  body text,
  pdf_storage_path text,
  pdf_sha256 text,
  snapshotted_at timestamptz not null default now(),
  snapshotted_by uuid default auth.uid()
);

alter table public.documents add column if not exists selected_sales_terms_id uuid references public.sales_terms(id) on delete set null;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('company-sales-terms','company-sales-terms',false,10485760,array['application/pdf'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf'];

do $$
declare table_name text;
begin
  foreach table_name in array array['external_connections','external_sync_states','external_sync_jobs','external_event_links','external_mail_links','sales_terms','sales_terms_versions','sales_terms_assignments','document_sales_terms_snapshots'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
  end loop;
end $$;

-- A collaborator manages only their own connection. Owners/admins can view
-- connection status for support, never its encrypted credentials.
create policy external_connections_insert on public.external_connections for insert to authenticated
  with check(
    public.is_company_member(company_id) and user_id=auth.uid() and created_by=auth.uid()
    and (connection_scope='personal' or public.has_company_role(company_id,array['owner','admin']))
  );
create policy external_connections_update on public.external_connections for update to authenticated
  using(
    public.is_company_member(company_id)
    and (user_id=auth.uid() or (connection_scope<>'personal' and public.has_company_role(company_id,array['owner','admin'])))
  )
  with check(
    public.is_company_member(company_id)
    and (user_id=auth.uid() or (connection_scope<>'personal' and public.has_company_role(company_id,array['owner','admin'])))
  );
create policy external_connections_delete on public.external_connections for delete to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid());

alter table public.external_connection_secrets enable row level security;
alter table public.external_oauth_states enable row level security;
revoke all on public.external_connection_secrets,public.external_oauth_states from public,anon,authenticated;
grant select,insert,update,delete on public.external_connection_secrets,public.external_oauth_states to service_role;

do $$
declare table_name text;
begin
  foreach table_name in array array['sales_terms','sales_terms_versions','sales_terms_assignments'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_permission(company_id,''manage_document_templates'') and created_by=auth.uid())',table_name||'_insert',table_name);
    execute format('create policy %I on public.%I for update to authenticated using(public.has_company_permission(company_id,''manage_document_templates'')) with check(public.has_company_permission(company_id,''manage_document_templates''))',table_name||'_update',table_name);
  end loop;
end $$;

create policy company_sales_terms_read on storage.objects for select to authenticated using(
  bucket_id='company-sales-terms' and public.is_company_member((storage.foldername(name))[1]::uuid)
);
create policy company_sales_terms_write on storage.objects for insert to authenticated with check(
  bucket_id='company-sales-terms' and public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_document_templates')
);

create or replace function public.create_sales_terms_version(
  target_company_id uuid,target_name text,target_source_type text,target_body text default null,
  target_pdf_storage_path text default null,target_pdf_sha256 text default null,target_mime_type text default null,
  target_file_size_bytes bigint default null,target_sales_terms_id uuid default null,target_change_comment text default null
) returns public.sales_terms_versions
language plpgsql security definer set search_path=public,pg_temp as $$
declare terms_row public.sales_terms; version_row public.sales_terms_versions; next_version integer;
begin
  if not public.has_company_permission(target_company_id,'manage_document_templates') then raise exception 'forbidden' using errcode='42501'; end if;
  if target_sales_terms_id is null then
    insert into public.sales_terms(company_id,name,created_by,updated_by) values(target_company_id,trim(target_name),auth.uid(),auth.uid()) returning * into terms_row;
  else
    select * into terms_row from public.sales_terms where id=target_sales_terms_id and company_id=target_company_id for update;
    if terms_row.id is null then raise exception 'sales_terms_not_found' using errcode='P0002'; end if;
  end if;
  select coalesce(max(version),0)+1 into next_version from public.sales_terms_versions where sales_terms_id=terms_row.id;
  insert into public.sales_terms_versions(company_id,sales_terms_id,version,source_type,body,pdf_storage_path,pdf_sha256,mime_type,file_size_bytes,change_comment,created_by)
  values(target_company_id,terms_row.id,next_version,target_source_type,target_body,target_pdf_storage_path,target_pdf_sha256,target_mime_type,target_file_size_bytes,target_change_comment,auth.uid()) returning * into version_row;
  update public.sales_terms set current_version=next_version,updated_by=auth.uid(),updated_at=now() where id=terms_row.id;
  return version_row;
end;
$$;

create or replace function public.resolve_document_sales_terms(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents; terms_id uuid; version_id uuid;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  terms_id:=doc.selected_sales_terms_id;
  if terms_id is null then
    select assignment.sales_terms_id into terms_id from public.sales_terms_assignments assignment
    where assignment.company_id=doc.company_id and assignment.active
      and (assignment.client_id=doc.client_id or assignment.client_id is null)
      and (assignment.document_type=doc.document_type or assignment.document_type is null)
    order by (assignment.client_id is not null) desc,assignment.priority desc,assignment.created_at desc limit 1;
  end if;
  if terms_id is null then return null; end if;
  select version.id into version_id from public.sales_terms terms join public.sales_terms_versions version on version.sales_terms_id=terms.id and version.version=terms.current_version
  where terms.id=terms_id and terms.company_id=doc.company_id and terms.status='active';
  return version_id;
end;
$$;

revoke all on function public.create_sales_terms_version(uuid,text,text,text,text,text,text,bigint,uuid,text) from public,anon;
revoke all on function public.resolve_document_sales_terms(uuid) from public,anon;
grant execute on function public.create_sales_terms_version(uuid,text,text,text,text,text,text,bigint,uuid,text) to authenticated;
grant execute on function public.resolve_document_sales_terms(uuid) to authenticated;

grant select,insert,update,delete on public.external_connections to authenticated;
grant select on public.external_sync_states,public.external_sync_jobs,public.external_event_links,public.external_mail_links to authenticated;
grant select,insert,update on public.sales_terms,public.sales_terms_versions,public.sales_terms_assignments to authenticated;
grant select on public.document_sales_terms_snapshots to authenticated;

commit;
