begin;

-- Les lignes comptables sont persistantes. Une ancienne ligne creee avant le
-- passage au compte individualise ne doit donc jamais reapparaitre dans une
-- nouvelle previsualisation. Cette reconciliation ne modifie volontairement
-- aucun lot deja valide afin de preserver la piste d'audit.
create or replace function public.reconcile_unexported_customer_account_lines(
  target_company_id uuid
) returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare
  selected_mode text;
  client_row record;
  changed_count integer:=0;
begin
  select coalesce(settings.customer_account_mode,'individualized')
  into selected_mode
  from public.accounting_settings settings
  where settings.company_id=target_company_id;

  selected_mode:=coalesce(selected_mode,'individualized');
  if selected_mode<>'individualized' then return 0;end if;

  -- Le compte est attribue une seule fois et conserve sur la fiche client.
  for client_row in
    select distinct client.id,
      coalesce(
        nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),
        'Client'
      ) display_label
    from public.accounting_entry_lines line
    join public.accounting_entries entry on entry.id=line.entry_id
    join public.clients client
      on client.id=line.third_party_id and client.company_id=entry.company_id
    where entry.company_id=target_company_id
      and not exists(
        select 1
        from public.accounting_export_batch_entries exported
        join public.accounting_export_batches batch
          on batch.id=exported.export_batch_id and batch.status='validated'
        where exported.accounting_entry_id=entry.id
      )
  loop
    perform public.ensure_client_individual_account(
      target_company_id,client_row.id,client_row.display_label
    );
  end loop;

  update public.accounting_entry_lines line
  set account_code=profile.individual_account_code,
      account_label=coalesce(
        nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),
        'Client'
      ),
      auxiliary_code=null,
      auxiliary_label=null
  from public.accounting_entries entry
  join public.clients client on client.company_id=entry.company_id
  join public.client_accounting_profiles profile
    on profile.client_id=client.id
   and profile.company_id=client.company_id
   and profile.active
  where line.entry_id=entry.id
    and entry.company_id=target_company_id
    and line.third_party_id=client.id
    and profile.individual_account_code is not null
    and not exists(
      select 1
      from public.accounting_export_batch_entries exported
      join public.accounting_export_batches batch
        on batch.id=exported.export_batch_id and batch.status='validated'
      where exported.accounting_entry_id=entry.id
    )
    and (
      line.account_code is distinct from profile.individual_account_code
      or line.account_label is distinct from coalesce(
        nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),
        'Client'
      )
      or line.auxiliary_code is not null
      or line.auxiliary_label is not null
    );
  get diagnostics changed_count=row_count;
  return changed_count;
end
$$;

-- Une modification explicite du mode remet immediatement les lignes encore
-- exportables en conformite avec le mode par defaut demande.
create or replace function public.accounting_customer_mode_reconcile_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT'
     or new.customer_account_mode is distinct from old.customer_account_mode then
    perform public.reconcile_unexported_customer_account_lines(new.company_id);
  end if;
  return new;
end
$$;

drop trigger if exists accounting_settings_reconcile_customer_mode
  on public.accounting_settings;
create trigger accounting_settings_reconcile_customer_mode
after insert or update of customer_account_mode on public.accounting_settings
for each row execute function public.accounting_customer_mode_reconcile_trigger();

-- Le mode individualise redevient le mode actif de toutes les entreprises
-- existantes lors de cette mise a niveau. Le mode collectif ne pourra ensuite
-- etre utilise que par une selection explicite dans les parametres.
update public.accounting_settings
set customer_account_mode='individualized',updated_at=now()
where customer_account_mode is distinct from 'individualized';

do $reconcile_existing_companies$
declare company_row record;
begin
  for company_row in select company_id from public.accounting_settings loop
    perform public.reconcile_unexported_customer_account_lines(company_row.company_id);
  end loop;
end
$reconcile_existing_companies$;

-- La previsualisation est la source de la validation et du fichier final.
-- Elle recale donc les donnees persistantes avant toute lecture/export.
do $patch_preview_customer_reconciliation$
declare
  source_definition text;
  patched_definition text;
  period_check text:='if target_ends_on<target_starts_on then raise exception ''invalid_period'';end if;';
begin
  source_definition:=pg_get_functiondef(
    'public.preview_accounting_export(uuid,text,date,date,text,boolean)'::regprocedure
  );
  if position('perform public.reconcile_unexported_customer_account_lines(target_company_id);' in source_definition)=0 then
    patched_definition:=replace(
      source_definition,
      period_check,
      'perform public.reconcile_unexported_customer_account_lines(target_company_id);'||chr(10)||
      '  '||period_check
    );
    if patched_definition=source_definition then
      raise exception 'accounting_export_reconciliation_patch_not_applied';
    end if;
    execute patched_definition;
  end if;
end
$patch_preview_customer_reconciliation$;

revoke all on function public.reconcile_unexported_customer_account_lines(uuid)
  from public,anon,authenticated;
revoke all on function public.accounting_customer_mode_reconcile_trigger()
  from public,anon,authenticated;

comment on function public.reconcile_unexported_customer_account_lines(uuid) is
  'Repare avant export les lignes clients non figees : CompteNum=411+identifiant persistant, CompteLib=nom reel, auxiliaires vides.';

alter table public.company_fiscal_configurations
  alter column schema_version set default '202607270089';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.43',schema_version='202607270089',updated_at=now()
where application_version is distinct from '0.9.0-compliance.43'
   or schema_version is distinct from '202607270089';

commit;
