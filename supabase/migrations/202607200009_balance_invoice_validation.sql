-- Allow balance invoices to follow the same immutable, atomic validation workflow
-- as standard and deposit invoices. This migration changes no existing data.

create or replace function public.validate_invoice(target_document_id uuid)
returns public.documents
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null
     or doc.document_type not in ('invoice','deposit_invoice','balance_invoice','credit_note')
     or doc.status <> 'draft'
  then
    raise exception 'invalid_invoice_state';
  end if;
  if not public.is_company_member(doc.company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.documents
     set number=coalesce(number,public.next_document_number(doc.company_id,doc.document_type)),
         validated_at=now(),
         status='validated'
   where id=doc.id
   returning * into doc;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data)
  values(doc.company_id,'invoice.validated','document',doc.id,to_jsonb(doc));
  return doc;
end $$;

revoke all on function public.validate_invoice(uuid) from public,anon;
grant execute on function public.validate_invoice(uuid) to authenticated,service_role;

create or replace function public.enforce_balance_invoice_validation_rpc()
returns trigger
language plpgsql
set search_path=public,pg_temp
as $$
begin
  if new.document_type='balance_invoice'
     and new.status='validated'
     and old.status is distinct from new.status
     and current_user not in ('postgres','service_role','supabase_admin')
  then
    raise exception 'workflow_rpc_required' using errcode='42501';
  end if;
  return new;
end $$;

drop trigger if exists balance_invoice_enforce_atomic_validation on public.documents;
create trigger balance_invoice_enforce_atomic_validation
before update on public.documents
for each row execute function public.enforce_balance_invoice_validation_rpc();

revoke all on function public.enforce_balance_invoice_validation_rpc() from public,anon,authenticated;
