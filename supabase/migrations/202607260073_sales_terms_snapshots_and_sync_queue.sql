begin;

alter table public.document_sales_terms_snapshots
  add column if not exists version integer,
  add column if not exists mime_type text,
  add column if not exists file_size_bytes bigint;

create or replace function public.assign_sales_terms(
  target_company_id uuid,
  target_sales_terms_id uuid,
  target_document_type text,
  target_client_id uuid default null,
  target_priority integer default 0,
  target_active boolean default true
) returns public.sales_terms_assignments
language plpgsql security definer set search_path=public,pg_temp as $$
declare assignment public.sales_terms_assignments;
begin
  if not public.has_company_permission(target_company_id,'manage_document_templates') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_document_type not in('quote','invoice','credit_note','sales_order','purchase_order') then
    raise exception 'invalid_document_type';
  end if;
  if not exists(select 1 from public.sales_terms where id=target_sales_terms_id and company_id=target_company_id and status='active') then
    raise exception 'sales_terms_not_found' using errcode='P0002';
  end if;
  if target_client_id is not null and not exists(select 1 from public.clients where id=target_client_id and company_id=target_company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  delete from public.sales_terms_assignments existing
  where existing.company_id=target_company_id
    and existing.client_id is not distinct from target_client_id
    and existing.document_type=target_document_type;
  insert into public.sales_terms_assignments(company_id,sales_terms_id,client_id,document_type,is_default,priority,active,created_by)
  values(target_company_id,target_sales_terms_id,target_client_id,target_document_type,target_client_id is null,target_priority,target_active,auth.uid())
  returning * into assignment;
  return assignment;
end $$;

create or replace function public.resolve_document_sales_terms(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents;terms_id uuid;version_id uuid;family text;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  family:=case when doc.document_type='quote' then 'quote'
    when doc.document_type in('invoice','deposit_invoice','balance_invoice','progress_invoice','proforma_invoice') then 'invoice'
    when doc.document_type='credit_note' then 'credit_note'
    else doc.document_type end;
  terms_id:=doc.selected_sales_terms_id;
  if terms_id is null then
    select assignment.sales_terms_id into terms_id from public.sales_terms_assignments assignment
    where assignment.company_id=doc.company_id and assignment.active
      and (assignment.client_id=doc.client_id or assignment.client_id is null)
      and assignment.document_type=family
    order by (assignment.client_id is not null) desc,assignment.priority desc,assignment.created_at desc limit 1;
  end if;
  if terms_id is null then return null; end if;
  select version.id into version_id from public.sales_terms terms
  join public.sales_terms_versions version on version.sales_terms_id=terms.id and version.version=terms.current_version
  where terms.id=terms_id and terms.company_id=doc.company_id and terms.status='active';
  return version_id;
end $$;

create or replace function public._snapshot_document_sales_terms(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents;version_row public.sales_terms_versions;version_id uuid;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or doc.finalized_at is null then return null;end if;
  select snapshot.sales_terms_version_id into version_id from public.document_sales_terms_snapshots snapshot where snapshot.document_id=doc.id;
  if version_id is not null then return version_id;end if;
  -- The internal resolver is executed under the document company context.  The
  -- assignment is read once; final documents never follow later CGV changes.
  select version.* into version_row from public.sales_terms_versions version
  where version.id=(
    select candidate.id from public.sales_terms_versions candidate
    join public.sales_terms terms on terms.id=candidate.sales_terms_id
    left join public.sales_terms_assignments assignment on assignment.sales_terms_id=terms.id
      and assignment.company_id=doc.company_id and assignment.active
      and assignment.document_type=case when doc.document_type='quote' then 'quote' when doc.document_type='credit_note' then 'credit_note' else 'invoice' end
      and (assignment.client_id=doc.client_id or assignment.client_id is null)
    where terms.company_id=doc.company_id and terms.status='active'
      and candidate.version=terms.current_version
      and (terms.id=doc.selected_sales_terms_id or (doc.selected_sales_terms_id is null and assignment.id is not null))
    order by (terms.id=doc.selected_sales_terms_id) desc,(assignment.client_id is not null) desc,assignment.priority desc,assignment.created_at desc
    limit 1
  );
  if version_row.id is null then return null;end if;
  insert into public.document_sales_terms_snapshots(document_id,company_id,sales_terms_id,sales_terms_version_id,version,source_type,body,pdf_storage_path,pdf_sha256,mime_type,file_size_bytes,snapshotted_by)
  values(doc.id,doc.company_id,version_row.sales_terms_id,version_row.id,version_row.version,version_row.source_type,version_row.body,version_row.pdf_storage_path,version_row.pdf_sha256,version_row.mime_type,version_row.file_size_bytes,coalesce(doc.finalized_by,doc.created_by));
  return version_row.id;
end $$;

create or replace function public.document_sales_terms_snapshot_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.finalized_at is null and new.finalized_at is not null then perform public._snapshot_document_sales_terms(new.id);end if;
  return new;
end $$;
drop trigger if exists documents_snapshot_sales_terms on public.documents;
create trigger documents_snapshot_sales_terms after update of finalized_at on public.documents
for each row execute function public.document_sales_terms_snapshot_trigger();

create or replace function public.prevent_document_sales_terms_snapshot_mutation()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'document_sales_terms_snapshot_immutable' using errcode='55000';end $$;
drop trigger if exists document_sales_terms_snapshots_immutable on public.document_sales_terms_snapshots;
create trigger document_sales_terms_snapshots_immutable before update or delete on public.document_sales_terms_snapshots
for each row execute function public.prevent_document_sales_terms_snapshot_mutation();

drop policy if exists company_sales_terms_update on storage.objects;
create policy company_sales_terms_update on storage.objects for update to authenticated
using(bucket_id='company-sales-terms' and public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_document_templates'))
with check(bucket_id='company-sales-terms' and public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_document_templates'));
drop policy if exists company_sales_terms_delete on storage.objects;
create policy company_sales_terms_delete on storage.objects for delete to authenticated
using(bucket_id='company-sales-terms' and public.has_company_permission((storage.foldername(name))[1]::uuid,'manage_document_templates'));

create or replace function public.enqueue_external_connection_maintenance(target_now timestamptz default now())
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare queued integer:=0;
begin
  if auth.uid() is not null and not exists(select 1 from public.company_members member where member.user_id=auth.uid() and member.role in('owner','admin')) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  insert into public.external_sync_jobs(company_id,connection_id,job_type,idempotency_key,payload,next_attempt_at)
  select connection.company_id,connection.id,
    case when state.webhook_expires_at is not null and state.webhook_expires_at<target_now+interval '24 hours' then 'renew_subscription' else 'incremental_sync' end,
    to_char(target_now at time zone 'UTC','YYYYMMDDHH24')||':'||state.resource_type||':'||state.resource_id,
    jsonb_build_object('resource_type',state.resource_type,'resource_id',state.resource_id),target_now
  from public.external_connections connection
  join public.external_sync_states state on state.connection_id=connection.id
  where connection.status='connected'
    and (state.last_successful_sync_at is null or state.last_successful_sync_at<target_now-interval '15 minutes'
      or state.webhook_expires_at is not null and state.webhook_expires_at<target_now+interval '24 hours')
  on conflict(connection_id,idempotency_key) do nothing;
  get diagnostics queued=row_count;
  update public.external_sync_jobs set status='dead_letter',completed_at=target_now
  where status='retry' and attempt_count>=8 and next_attempt_at<=target_now;
  return queued;
end $$;

revoke all on function public.assign_sales_terms(uuid,uuid,text,uuid,integer,boolean) from public,anon;
grant execute on function public.assign_sales_terms(uuid,uuid,text,uuid,integer,boolean) to authenticated;
revoke all on function public._snapshot_document_sales_terms(uuid) from public,anon,authenticated;
revoke all on function public.enqueue_external_connection_maintenance(timestamptz) from public,anon,authenticated;
grant execute on function public.enqueue_external_connection_maintenance(timestamptz) to service_role;
revoke insert,update,delete on public.document_sales_terms_snapshots from authenticated;

create or replace function public.accounting_settings_audit_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.accounting_config_history(company_id,table_name,record_id,old_value,new_value,changed_by)
  values(coalesce(new.company_id,old.company_id),'accounting_settings',null,
    case when tg_op='INSERT' then null else to_jsonb(old) end,
    case when tg_op='DELETE' then null else to_jsonb(new) end,auth.uid());
  return coalesce(new,old);
end $$;
drop trigger if exists accounting_settings_audit on public.accounting_settings;
create trigger accounting_settings_audit after insert or update or delete on public.accounting_settings
for each row execute function public.accounting_settings_audit_trigger();
drop trigger if exists accounting_fiscal_years_audit on public.accounting_fiscal_years;
create trigger accounting_fiscal_years_audit after insert or update or delete on public.accounting_fiscal_years
for each row execute function public.accounting_config_audit_trigger();

revoke all on function public._bootstrap_company_accounting(uuid,date) from public,anon,authenticated;
revoke all on function public.next_accounting_entry_number(uuid,date) from public,anon,authenticated;
revoke all on function public.ensure_accounting_third_party_identifier(uuid,text,uuid,text) from public,anon,authenticated;
revoke all on function public._generate_document_accounting_entry(uuid) from public,anon,authenticated;
revoke all on function public._generate_payment_accounting_entry(public.payments) from public,anon,authenticated;
revoke all on function public.accounting_settings_audit_trigger() from public,anon,authenticated;

commit;
