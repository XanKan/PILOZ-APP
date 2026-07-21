-- Compléments fonctionnels non destructifs : entreprise, achats, encaissements et envoi.
-- Toutes les nouvelles données restent portées par des tables déjà isolées par company_id.
begin;

alter table public.user_preferences
  add column if not exists first_name text,
  add column if not exists last_name text,
  add column if not exists display_name text;

alter table public.company_settings
  add column if not exists company_type text,
  add column if not exists description text,
  add column if not exists secondary_phone text,
  add column if not exists primary_contact_name text,
  add column if not exists rcs_number text,
  add column if not exists social_capital numeric(15,2),
  add column if not exists registry_court text,
  add column if not exists legal_mentions text,
  add column if not exists vat_frequency text,
  add column if not exists fiscal_year_start text,
  add column if not exists vat_franchise text;

alter table public.company_document_settings
  add column if not exists mandate_reference text;

alter table public.purchase_orders
  add column if not exists delivery_address_id uuid references public.company_addresses(id) on delete set null,
  add column if not exists purchase_terms text,
  add column if not exists payment_method text,
  add column if not exists supplier_reference text,
  add column if not exists assigned_user_id uuid,
  add column if not exists internal_notes text,
  add column if not exists sent_at timestamptz,
  add column if not exists confirmed_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table public.documents add column if not exists sent_at timestamptz;
grant select(sent_at) on public.documents to authenticated;

alter table public.payments
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid,
  add column if not exists cancellation_reason text;

alter table public.company_settings
  drop constraint if exists company_settings_social_capital_nonnegative;
alter table public.company_settings
  add constraint company_settings_social_capital_nonnegative check(social_capital is null or social_capital>=0) not valid;

alter table public.payments
  drop constraint if exists payments_cancellation_trace_check;
alter table public.payments
  add constraint payments_cancellation_trace_check check(
    status<>'cancelled' or (cancelled_at is not null and cancelled_by is not null and nullif(trim(cancellation_reason),'') is not null)
  ) not valid;

create or replace function public.cancel_document_payment(target_payment_id uuid,cancellation_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  target public.payments%rowtype;
  doc public.documents%rowtype;
  confirmed_total numeric;
  remaining numeric;
  schedule_row public.payment_schedules%rowtype;
  allocation numeric;
begin
  if nullif(trim($2),'') is null then raise exception 'cancellation_reason_required'; end if;
  select * into target from public.payments where id=target_payment_id for update;
  if target.id is null or target.status<>'confirmed' then raise exception 'invalid_payment_state'; end if;
  if not public.is_company_member(target.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select * into doc from public.documents where id=target.document_id for update;

  update public.payments set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim($2),updated_at=now()
  where id=target.id;

  select coalesce(sum(amount),0) into confirmed_total from public.payments where document_id=doc.id and status='confirmed';
  update public.payment_schedules set paid_amount=0,status='pending',updated_at=now() where document_id=doc.id and status<>'cancelled';
  remaining:=confirmed_total;
  for schedule_row in select * from public.payment_schedules where document_id=doc.id and status<>'cancelled' order by due_date,id for update loop
    allocation:=least(remaining,schedule_row.amount);
    update public.payment_schedules set paid_amount=allocation,status=case when allocation>=amount then 'paid' when allocation>0 then 'partial' else 'pending' end where id=schedule_row.id;
    remaining:=greatest(0,remaining-allocation);
  end loop;

  update public.documents set status=case when confirmed_total>=total_incl_tax-0.01 then 'paid' when confirmed_total>0 then 'partially_paid' else 'validated' end,updated_at=now()
  where id=doc.id;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,old_data,new_data)
  values(target.company_id,'payment.cancelled','payment',target.id,to_jsonb(target),jsonb_build_object('reason',trim($2),'cancelled_by',auth.uid()));
  return target.id;
end $$;

create or replace function public.reopen_invoice_for_correction(target_document_id uuid,reopen_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.documents%rowtype;
begin
  if nullif(trim(reopen_reason),'') is null then raise exception 'reopen_reason_required'; end if;
  select * into target from public.documents where id=target_document_id for update;
  if target.id is null or target.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') or target.validated_at is null then raise exception 'invalid_invoice_state'; end if;
  if not public.has_company_role(target.company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  if exists(select 1 from public.payments where document_id=target.id and status='confirmed') then raise exception 'cancel_payments_before_reopen'; end if;
  update public.documents set status='draft',validated_at=null,number=null,updated_at=now() where id=target.id;
  insert into public.activity_logs(company_id,action,entity_type,entity_id,old_data,new_data)
  values(target.company_id,'invoice.reopened','document',target.id,to_jsonb(target),jsonb_build_object('reason',trim(reopen_reason),'reopened_by',auth.uid()));
  return target.id;
end $$;

-- Les écritures directes restent verrouillées. Les RPC SECURITY DEFINER ci-dessus sont
-- les seuls chemins autorisés pour retirer la validation d'une facture.
create or replace function public.protect_validated_document()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if current_user in('postgres','service_role','supabase_admin') then return new; end if;
  if old.validated_at is not null and
     (to_jsonb(new)-array['status','archived_at','sent_at','last_reminder_at','updated_at']::text[]) is distinct from
     (to_jsonb(old)-array['status','archived_at','sent_at','last_reminder_at','updated_at']::text[])
  then raise exception 'validated_document_is_locked' using errcode='55000'; end if;
  return new;
end $$;

revoke all on function public.cancel_document_payment(uuid,text) from public,anon;
revoke all on function public.reopen_invoice_for_correction(uuid,text) from public,anon;
grant execute on function public.cancel_document_payment(uuid,text) to authenticated,service_role;
grant execute on function public.reopen_invoice_for_correction(uuid,text) to authenticated,service_role;

commit;
