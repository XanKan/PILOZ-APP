begin;

-- Le mode comptable client par defaut porte l'identite du tiers directement
-- dans CompteNum. Le mode collectif + auxiliaire reste disponible uniquement
-- lorsqu'il est explicitement selectionne dans les parametres comptables.
alter table public.accounting_settings
  add column if not exists customer_account_mode text not null default 'individualized';

alter table public.accounting_settings
  drop constraint if exists accounting_settings_customer_account_mode_check;
alter table public.accounting_settings
  add constraint accounting_settings_customer_account_mode_check
  check(customer_account_mode in('individualized','collective_auxiliary')) not valid;

update public.accounting_settings
set customer_account_mode='individualized',updated_at=now()
where customer_account_mode is distinct from 'individualized';

alter table public.accounting_settings
  validate constraint accounting_settings_customer_account_mode_check;

alter table public.client_accounting_profiles
  add column if not exists individual_account_code text;

alter table public.client_accounting_profiles
  drop constraint if exists client_accounting_profiles_individual_account_code_check;
alter table public.client_accounting_profiles
  add constraint client_accounting_profiles_individual_account_code_check
  check(individual_account_code is null or individual_account_code~'^411[A-Z0-9]+$') not valid;

create unique index if not exists client_accounting_profiles_individual_account_unique
  on public.client_accounting_profiles(company_id,individual_account_code)
  where active and individual_account_code is not null;

alter table public.client_account_history
  add column if not exists previous_individual_account text,
  add column if not exists new_individual_account text;

-- Normalisation stable : majuscules, accents supprimes, ligatures developpees,
-- puis conservation exclusive des lettres et chiffres.
create or replace function public.normalized_customer_account_suffix(raw_label text)
returns text language sql immutable set search_path=public,pg_temp as $$
  with expanded as(
    select replace(replace(upper(coalesce(raw_label,'')),chr(338),'OE'),chr(198),'AE') value
  )
  select coalesce(nullif(regexp_replace(
    translate(value,
      chr(192)||chr(193)||chr(194)||chr(195)||chr(196)||chr(197)||chr(199)||
      chr(200)||chr(201)||chr(202)||chr(203)||chr(204)||chr(205)||chr(206)||
      chr(207)||chr(209)||chr(210)||chr(211)||chr(212)||chr(213)||chr(214)||
      chr(217)||chr(218)||chr(219)||chr(220)||chr(221)||chr(376),
      'AAAAAACEEEEIIIINOOOOOUUUUYY'),
    '[^A-Z0-9]','','g'),''),'CLIENT')
  from expanded
$$;

create or replace function public.ensure_client_individual_account(
  target_company_id uuid,target_client_id uuid,target_label text
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare
  client_row public.clients%rowtype;
  existing_code text;
  base_code text;
  candidate text;
  suffix integer:=1;
  actor_id uuid;
begin
  select * into client_row
  from public.clients
  where id=target_client_id and company_id=target_company_id;
  if client_row.id is null then raise exception 'client_not_found' using errcode='P0002';end if;

  select individual_account_code into existing_code
  from public.client_accounting_profiles
  where company_id=target_company_id and client_id=target_client_id and active;
  if existing_code is not null then return existing_code;end if;

  base_code:='411'||public.normalized_customer_account_suffix(target_label);
  candidate:=base_code;
  while exists(
    select 1 from public.client_accounting_profiles profile
    where profile.company_id=target_company_id
      and profile.client_id<>target_client_id
      and profile.active
      and profile.individual_account_code=candidate
  ) loop
    suffix:=suffix+1;
    candidate:=base_code||suffix::text;
  end loop;

  actor_id:=coalesce(auth.uid(),client_row.created_by);
  insert into public.client_accounting_profiles(
    company_id,client_id,collective_account,auxiliary_account,individual_account_code,
    assignment_mode,accounting_label,active,effective_from,created_by,updated_by
  ) values(
    target_company_id,target_client_id,'411',null,candidate,'automatic',
    coalesce(nullif(trim(target_label),''),'Client'),true,current_date,actor_id,actor_id
  ) on conflict(client_id) do update set
    individual_account_code=coalesce(public.client_accounting_profiles.individual_account_code,excluded.individual_account_code),
    accounting_label=coalesce(nullif(public.client_accounting_profiles.accounting_label,''),excluded.accounting_label),
    active=true,updated_by=coalesce(auth.uid(),public.client_accounting_profiles.updated_by),updated_at=now()
  returning individual_account_code into existing_code;
  return existing_code;
end
$$;

-- Affecte une seule fois un compte individualise a chaque client existant.
-- Les homonymes sont distingues par un suffixe numerique stable.
do $seed_individual_customer_accounts$
declare client_row record;
begin
  for client_row in
    select client.id,client.company_id,
      coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client') label
    from public.clients client
    order by client.company_id,client.created_at,client.id
  loop
    perform public.ensure_client_individual_account(client_row.company_id,client_row.id,client_row.label);
  end loop;
end
$seed_individual_customer_accounts$;

alter table public.client_accounting_profiles
  validate constraint client_accounting_profiles_individual_account_code_check;

-- Modification volontaire depuis la fiche client. Un compte deja present
-- dans un export valide reste verrouille afin de proteger la piste d'audit.
create or replace function public.assign_client_individual_account(
  target_client_id uuid,
  target_account_code text default null,
  target_reason text default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  actor_id uuid:=auth.uid();
  client_row public.clients%rowtype;
  profile public.client_accounting_profiles%rowtype;
  previous_code text;
  proposed_code text;
  display_label text;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000';end if;
  select * into client_row from public.clients where id=target_client_id for update;
  if client_row.id is null or not public.is_company_member(client_row.company_id) then
    raise exception 'client_not_found' using errcode='P0002';
  end if;
  if not public.has_company_role(client_row.company_id,array['owner','admin','accounting'])
     and not public.has_company_permission(client_row.company_id,'manage_customer')
     and not public.has_company_permission(client_row.company_id,'clients.write') then
    raise exception 'forbidden' using errcode='42501';
  end if;

  display_label:=coalesce(nullif(trim(coalesce(client_row.legal_name,concat_ws(' ',client_row.first_name,client_row.last_name))),''),'Client');
  select * into profile from public.client_accounting_profiles where client_id=client_row.id for update;
  previous_code:=profile.individual_account_code;
  proposed_code:=regexp_replace(upper(coalesce(target_account_code,'')),'[^A-Z0-9]','','g');
  if proposed_code='' then proposed_code:='411'||public.normalized_customer_account_suffix(display_label);end if;
  if proposed_code!~'^411[A-Z0-9]+$' then raise exception 'invalid_individual_account' using errcode='22023';end if;
  if exists(
    select 1 from public.client_accounting_profiles existing
    where existing.company_id=client_row.company_id and existing.client_id<>client_row.id
      and existing.active and existing.individual_account_code=proposed_code
  ) then raise exception 'individual_account_already_used' using errcode='23505';end if;
  if previous_code is distinct from proposed_code and exists(
    select 1
    from public.accounting_entry_lines line
    join public.accounting_entries entry on entry.id=line.entry_id
    join public.accounting_export_batch_entries exported on exported.accounting_entry_id=entry.id
    join public.accounting_export_batches batch on batch.id=exported.export_batch_id and batch.status='validated'
    where line.third_party_id=client_row.id
  ) then raise exception 'individual_account_locked_by_export' using errcode='55000';end if;

  insert into public.client_accounting_profiles(
    company_id,client_id,collective_account,auxiliary_account,individual_account_code,
    assignment_mode,accounting_label,active,effective_from,internal_comment,created_by,updated_by
  ) values(
    client_row.company_id,client_row.id,'411',null,proposed_code,'manual',display_label,
    true,current_date,nullif(target_reason,''),actor_id,actor_id
  ) on conflict(client_id) do update set
    individual_account_code=excluded.individual_account_code,assignment_mode='manual',
    accounting_label=excluded.accounting_label,internal_comment=excluded.internal_comment,
    active=true,updated_by=actor_id,updated_at=now()
  returning * into profile;

  if previous_code is distinct from proposed_code then
    insert into public.client_account_history(
      company_id,client_id,previous_individual_account,new_individual_account,
      collective_account,assignment_mode,effective_from,reason,changed_by,created_by
    ) values(
      client_row.company_id,client_row.id,previous_code,proposed_code,'411','manual',
      current_date,nullif(target_reason,''),actor_id,actor_id
    );
  end if;

  update public.accounting_entry_lines line
  set account_code=proposed_code,account_label=display_label,
      auxiliary_code=null,auxiliary_label=null
  from public.accounting_entries entry
  where line.entry_id=entry.id and line.third_party_id=client_row.id
    and not exists(
      select 1 from public.accounting_export_batch_entries exported
      join public.accounting_export_batches batch on batch.id=exported.export_batch_id
      where exported.accounting_entry_id=entry.id and batch.status='validated'
    );
  return to_jsonb(profile);
end
$$;

-- Recale les ecritures non figees. Les exports valides restent strictement
-- immuables et conservent leur instantane historique.
update public.accounting_entry_lines line
set account_code=profile.individual_account_code,
    account_label=coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client'),
    auxiliary_code=null,
    auxiliary_label=null
from public.accounting_entries entry
join public.clients client on client.company_id=entry.company_id
join public.client_accounting_profiles profile on profile.client_id=client.id and profile.company_id=client.company_id and profile.active
where line.entry_id=entry.id
  and client.id=line.third_party_id
  and profile.individual_account_code is not null
  and not exists(
    select 1 from public.accounting_export_batch_entries exported
    join public.accounting_export_batches batch on batch.id=exported.export_batch_id
    where exported.accounting_entry_id=entry.id and batch.status='validated'
  );

-- Le generateur de factures/avoirs applique le mode par defaut individualise.
do $patch_document_customer_account$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public._generate_document_accounting_entry(uuid)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    'collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '    auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,''client'',doc.client_id,party_label));',
    'if coalesce(settings.customer_account_mode,''individualized'')=''individualized'' then'||chr(10)||
    '      collective:=public.ensure_client_individual_account(doc.company_id,doc.client_id,party_label);'||chr(10)||
    '      auxiliary:=null;'||chr(10)||
    '    else'||chr(10)||
    '      collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '      auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,''client'',doc.client_id,party_label));'||chr(10)||
    '    end if;'
  );
  patched_definition:=replace(
    patched_definition,
    'values(doc.company_id,entry_id,line_no,collective,case when direction=''sale'' then ''Client - '' else ''Fournisseur - '' end||party_label,auxiliary,party_label,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,''Document''),',
    'values(doc.company_id,entry_id,line_no,collective,case when direction=''sale'' then party_label else ''Fournisseur - ''||party_label end,auxiliary,case when auxiliary is null then null else party_label end,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,''Document''),'
  );
  if patched_definition=source_definition then raise exception 'document_customer_account_patch_not_applied';end if;
  execute patched_definition;
end
$patch_document_customer_account$;

-- Les reglements utilisent exactement le meme compte persistant que la facture.
do $patch_payment_customer_account$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public._generate_payment_accounting_entry(public.payments)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    'collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '  auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(target_payment.company_id,''client'',doc.client_id,party_label));financial:=',
    'if coalesce(settings.customer_account_mode,''individualized'')=''individualized'' then'||chr(10)||
    '    collective:=public.ensure_client_individual_account(target_payment.company_id,doc.client_id,party_label);'||chr(10)||
    '    auxiliary:=null;'||chr(10)||
    '  else'||chr(10)||
    '    collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '    auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(target_payment.company_id,''client'',doc.client_id,party_label));'||chr(10)||
    '  end if;'||chr(10)||
    '  financial:='
  );
  patched_definition:=replace(
    patched_definition,
    'update public.accounting_entry_lines target set auxiliary_code=auxiliary,auxiliary_label=party_label,third_party_id=doc.client_id where target.entry_id=generated_entry_id and target.line_number=2;',
    'update public.accounting_entry_lines target set auxiliary_code=auxiliary,auxiliary_label=case when auxiliary is null then null else party_label end,third_party_id=doc.client_id where target.entry_id=generated_entry_id and target.line_number=2;'
  );
  if patched_definition=source_definition then raise exception 'payment_customer_account_patch_not_applied';end if;
  execute patched_definition;
end
$patch_payment_customer_account$;

-- Expose le mode reel dans l'aperçu pour que l'interface n'affiche jamais une
-- regle auxiliaire lorsque le fichier contiendra un compte individualise.
do $patch_accounting_export_preview_mode$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public.preview_accounting_export(uuid,text,date,date,text,boolean)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    '''auxiliary_max_length'',auxiliary_max_length,'||chr(10)||
    '    ''accounts'',accounts,',
    '''auxiliary_max_length'',auxiliary_max_length,'||chr(10)||
    '    ''customer_account_mode'',coalesce((select customer_account_mode from public.accounting_settings where company_id=target_company_id),''individualized''),'||chr(10)||
    '    ''accounts'',accounts,'
  );
  if patched_definition=source_definition then raise exception 'accounting_export_preview_mode_patch_not_applied';end if;
  execute patched_definition;
end
$patch_accounting_export_preview_mode$;

-- Les listes clients exposent le meme compte que la fiche, tout en conservant
-- temporairement l'ancien alias JSON pour les clients web deja en cache.
do $patch_client_directory_accounts$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public.get_client_directory(uuid,text,text,text,uuid,integer,integer)'::regprocedure);
  patched_definition:=replace(source_definition,'account.auxiliary_account','account.individual_account_code');
  patched_definition:=replace(
    patched_definition,
    'coalesce(account.individual_account_code,'''') auxiliary_account',
    'coalesce(account.individual_account_code,'''') individual_account_code,coalesce(account.individual_account_code,'''') auxiliary_account'
  );
  if patched_definition=source_definition then raise exception 'client_directory_account_patch_not_applied';end if;
  execute patched_definition;

  source_definition:=pg_get_functiondef('public.get_client_directory_v2(uuid,text,jsonb,text,text,integer,integer)'::regprocedure);
  patched_definition:=replace(source_definition,'account.auxiliary_account','account.individual_account_code');
  patched_definition:=replace(
    patched_definition,
    'coalesce(account.individual_account_code,'''') auxiliary_account',
    'coalesce(account.individual_account_code,'''') individual_account_code,coalesce(account.individual_account_code,'''') auxiliary_account'
  );
  if patched_definition=source_definition then raise exception 'client_directory_v2_account_patch_not_applied';end if;
  execute patched_definition;
end
$patch_client_directory_accounts$;

revoke all on function public.ensure_client_individual_account(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.assign_client_individual_account(uuid,text,text) from public,anon;
grant execute on function public.assign_client_individual_account(uuid,text,text) to authenticated;

comment on column public.accounting_settings.customer_account_mode is
  'individualized: 411+identifiant dans CompteNum, auxiliaires vides (defaut); collective_auxiliary: compte collectif et auxiliaire explicites.';
comment on column public.client_accounting_profiles.individual_account_code is
  'Compte client persistant exporte directement dans CompteNum en mode individualized.';

alter table public.company_fiscal_configurations
  alter column schema_version set default '202607270088';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.42',schema_version='202607270088',updated_at=now()
where application_version is distinct from '0.9.0-compliance.42'
   or schema_version is distinct from '202607270088';

commit;
