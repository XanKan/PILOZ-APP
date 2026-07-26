begin;

-- Les exercices sont créés explicitement ou par la tâche serveur. Cette
-- fonction est additive : elle ne clôture et ne supprime aucune écriture.
create or replace function public.create_next_accounting_fiscal_year(target_fiscal_year_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  current_year public.accounting_fiscal_years%rowtype;
  next_year public.accounting_fiscal_years%rowtype;
  next_start date;
  next_end date;
  duration_days integer;
begin
  select * into current_year
  from public.accounting_fiscal_years
  where id=target_fiscal_year_id
  for update;
  if current_year.id is null then raise exception 'accounting_fiscal_year_not_found'; end if;
  if auth.uid() is not null and not public.has_company_permission(current_year.company_id,'accounting_fiscal_year_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;

  next_start:=current_year.ends_on+1;
  select * into next_year
  from public.accounting_fiscal_years
  where company_id=current_year.company_id and starts_on=next_start
  order by created_at
  limit 1;

  if next_year.id is null then
    duration_days:=(current_year.ends_on-current_year.starts_on)+1;
    next_end:=next_start+greatest(duration_days-1,0);
    insert into public.accounting_fiscal_years(
      company_id,name,starts_on,ends_on,status,previous_year_id,
      auto_create_next,auto_close,created_by,updated_by
    ) values(
      current_year.company_id,extract(year from next_start)::integer::text,
      next_start,next_end,'upcoming',current_year.id,
      current_year.auto_create_next,current_year.auto_close,auth.uid(),auth.uid()
    ) returning * into next_year;
  elsif next_year.previous_year_id is distinct from current_year.id then
    update public.accounting_fiscal_years
    set previous_year_id=current_year.id,updated_by=auth.uid(),updated_at=now()
    where id=next_year.id;
  end if;

  update public.accounting_fiscal_years
  set next_year_id=next_year.id,updated_by=auth.uid(),updated_at=now()
  where id=current_year.id and next_year_id is distinct from next_year.id;
  return next_year.id;
end;
$$;

create or replace function public.close_accounting_fiscal_year(target_fiscal_year_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  target_year public.accounting_fiscal_years%rowtype;
  next_id uuid;
  unbalanced_count integer:=0;
  missing_entry_count integer:=0;
begin
  select * into target_year from public.accounting_fiscal_years where id=target_fiscal_year_id for update;
  if target_year.id is null then raise exception 'accounting_fiscal_year_not_found'; end if;
  if not public.has_company_permission(target_year.company_id,'accounting_fiscal_year_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if target_year.status='closed' then return jsonb_build_object('closed',true,'already_closed',true,'fiscal_year_id',target_year.id); end if;

  select count(*) into unbalanced_count
  from public.accounting_entries entry
  left join lateral(
    select coalesce(sum(line.debit),0) debit,coalesce(sum(line.credit),0) credit
    from public.accounting_entry_lines line where line.entry_id=entry.id
  ) totals on true
  where entry.fiscal_year_id=target_year.id and abs(totals.debit-totals.credit)>0.01;
  if unbalanced_count>0 then raise exception 'accounting_fiscal_year_unbalanced_entries'; end if;

  select count(*) into missing_entry_count
  from public.documents document
  where document.company_id=target_year.company_id
    and document.issue_date between target_year.starts_on and target_year.ends_on
    and document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
    and document.finalized_at is not null
    and not exists(
      select 1 from public.accounting_entries entry
      where entry.document_id=document.id and entry.event_kind='original'
    );
  if missing_entry_count>0 then raise exception 'accounting_fiscal_year_missing_entries'; end if;

  if target_year.next_year_id is null and target_year.auto_create_next then
    next_id:=public.create_next_accounting_fiscal_year(target_year.id);
  else
    next_id:=target_year.next_year_id;
  end if;

  update public.accounting_fiscal_years
  set status='closed',closed_at=now(),closed_by=auth.uid(),updated_by=auth.uid(),updated_at=now()
  where id=target_year.id;
  if next_id is not null then
    update public.accounting_fiscal_years
    set status=case when current_date between starts_on and ends_on then 'open' else status end,
        updated_by=auth.uid(),updated_at=now()
    where id=next_id and status='upcoming';
  end if;
  return jsonb_build_object('closed',true,'already_closed',false,'fiscal_year_id',target_year.id,'next_year_id',next_id,'checked_at',now());
end;
$$;

-- Tâche serveur : prépare les clôtures arrivées à échéance, crée N+1 lorsque
-- l'option est active, expire les droits Stripe et nettoie les états OAuth.
-- Elle n'est jamais exécutable depuis le navigateur.
create or replace function public.run_accounting_fiscal_maintenance(target_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  target_date date:=(target_now at time zone 'UTC')::date;
  fiscal_row record;
  next_created integer:=0;
  prepared integer:=0;
  opened integer:=0;
  grants_expired integer:=0;
  oauth_states_deleted integer:=0;
  next_id uuid;
begin
  for fiscal_row in
    select id from public.accounting_fiscal_years
    where auto_create_next and next_year_id is null and ends_on<=target_date+90
    order by company_id,ends_on
  loop
    next_id:=public.create_next_accounting_fiscal_year(fiscal_row.id);
    if next_id is not null then next_created:=next_created+1; end if;
  end loop;

  update public.accounting_fiscal_years
  set status='to_close',updated_at=target_now
  where status='open' and ends_on<target_date;
  get diagnostics prepared=row_count;

  update public.accounting_fiscal_years candidate
  set status='open',updated_at=target_now
  where candidate.status='upcoming'
    and target_date between candidate.starts_on and candidate.ends_on
    and not exists(
      select 1 from public.accounting_fiscal_years active
      where active.company_id=candidate.company_id and active.status='open'
        and active.id<>candidate.id and target_date between active.starts_on and active.ends_on
    );
  get diagnostics opened=row_count;

  -- The cron worker has no end-user JWT, so it must not depend on auth.role().
  -- This function is already service-role-only and SECURITY DEFINER.
  update public.stripe_onboarding_grants
  set status='expired',updated_at=target_now
  where status='ready' and expires_at<=target_now;
  get diagnostics grants_expired=row_count;
  delete from public.external_oauth_states where expires_at<target_now-interval '1 day';
  get diagnostics oauth_states_deleted=row_count;

  return jsonb_build_object(
    'next_years_created',next_created,'years_prepared_for_closure',prepared,
    'years_opened',opened,'expired_grants_total',grants_expired,
    'oauth_states_deleted',oauth_states_deleted,'checked_at',target_now
  );
end;
$$;

revoke all on function public.create_next_accounting_fiscal_year(uuid) from public,anon;
grant execute on function public.create_next_accounting_fiscal_year(uuid) to authenticated,service_role;
revoke all on function public.close_accounting_fiscal_year(uuid) from public,anon;
grant execute on function public.close_accounting_fiscal_year(uuid) to authenticated;
revoke all on function public.run_accounting_fiscal_maintenance(timestamptz) from public,anon,authenticated;
grant execute on function public.run_accounting_fiscal_maintenance(timestamptz) to service_role;

do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron')
     and not exists(select 1 from cron.job where jobname='piloz-accounting-fiscal-maintenance') then
    perform cron.schedule(
      'piloz-accounting-fiscal-maintenance','17 2 * * *',
      $cron$select public.run_accounting_fiscal_maintenance(now());$cron$
    );
  end if;
exception when undefined_table or insufficient_privilege then
  raise notice 'pg_cron unavailable: schedule run_accounting_fiscal_maintenance externally';
end;
$$;

commit;
