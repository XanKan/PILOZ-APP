begin;

-- Le compte collectif client reste le 411. L'identifiant du tiers est porte
-- par le compte auxiliaire, comme dans le fichier de reference ProGBat.
alter table public.accounting_settings
  alter column customer_collective_account set default '411';

update public.accounting_settings
set customer_collective_account='411',
    auxiliary_length=least(10,greatest(1,coalesce(auxiliary_length,10))),
    updated_at=now()
where customer_collective_account='411000'
   or auxiliary_length>10
   or auxiliary_length<1;

update public.client_accounting_profiles
set collective_account='411',updated_at=now()
where collective_account='411000';

alter table public.accounting_settings
  drop constraint if exists accounting_settings_auxiliary_length_check;
alter table public.accounting_settings
  add constraint accounting_settings_auxiliary_length_check
  check(auxiliary_length between 1 and 10) not valid;

alter table public.accounting_third_party_identifiers
  drop constraint if exists accounting_third_party_identifiers_identifier_check;

-- Les anciens auxiliaires etaient artificiellement completes avec des traits
-- de soulignement. Ils deviennent des codes de longueur variable, uniques et
-- limites par le parametre de l'entreprise (10 caracteres au maximum).
do $normalize_existing_auxiliaries$
declare
  identifier_row record;
  identifier_length integer;
  base_identifier text;
  candidate text;
  suffix integer;
begin
  for identifier_row in
    select identifier.id,identifier.company_id,identifier.label,identifier.identifier,identifier.forced,
      coalesce(settings.auxiliary_length,10) configured_length
    from public.accounting_third_party_identifiers identifier
    left join public.accounting_settings settings on settings.company_id=identifier.company_id
    where identifier.effective_until is null
    order by identifier.company_id,identifier.created_at,identifier.id
  loop
    identifier_length:=least(10,greatest(1,identifier_row.configured_length));
    base_identifier:=regexp_replace(
      translate(upper(case when identifier_row.forced then coalesce(identifier_row.identifier,'') else coalesce(identifier_row.label,'') end),
        'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝŸŒÆ',
        'AAAAAACEEEEIIIINOOOOOUUUUYYOA'),
      '[^A-Z0-9]','','g'
    );
    candidate:=left(coalesce(nullif(base_identifier,''),'TIERS'),identifier_length);
    suffix:=0;
    while exists(
      select 1 from public.accounting_third_party_identifiers existing
      where existing.company_id=identifier_row.company_id
        and existing.effective_until is null
        and existing.id<>identifier_row.id
        and existing.identifier=candidate
    ) loop
      suffix:=suffix+1;
      candidate:=left(coalesce(nullif(base_identifier,''),'TIERS'),greatest(1,identifier_length-length(suffix::text)))||suffix::text;
    end loop;
    update public.accounting_third_party_identifiers
    set identifier=candidate
    where id=identifier_row.id and identifier is distinct from candidate;
  end loop;
end $normalize_existing_auxiliaries$;

alter table public.accounting_third_party_identifiers
  add constraint accounting_third_party_identifiers_identifier_check
  check(effective_until is not null or identifier~'^[A-Z0-9]{1,10}$') not valid;

alter table public.accounting_settings validate constraint accounting_settings_auxiliary_length_check;
alter table public.accounting_third_party_identifiers validate constraint accounting_third_party_identifiers_identifier_check;

create or replace function public.normalized_third_party_identifier(raw_label text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select left(coalesce(nullif(regexp_replace(
    translate(upper(coalesce(raw_label,'')),
      'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝŸŒÆ',
      'AAAAAACEEEEIIIINOOOOOUUUUYYOA'),
    '[^A-Z0-9]','','g'),''),'TIERS'),10)
$$;

create or replace function public.ensure_accounting_third_party_identifier(
  target_company_id uuid,target_party_type text,target_party_id uuid,target_label text
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare
  candidate text;
  suffix integer:=0;
  existing text;
  identifier_length integer:=10;
  base_identifier text;
begin
  select identifier into existing
  from public.accounting_third_party_identifiers
  where company_id=target_company_id
    and party_type=target_party_type
    and party_id=target_party_id
    and effective_until is null;
  if existing is not null then return existing;end if;

  select least(10,greatest(1,coalesce(auxiliary_length,10)))
  into identifier_length
  from public.accounting_settings
  where company_id=target_company_id;
  identifier_length:=coalesce(identifier_length,10);
  base_identifier:=regexp_replace(
    translate(upper(coalesce(target_label,'')),
      'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝŸŒÆ',
      'AAAAAACEEEEIIIINOOOOOUUUUYYOA'),
    '[^A-Z0-9]','','g'
  );
  candidate:=left(coalesce(nullif(base_identifier,''),'TIERS'),identifier_length);
  while exists(
    select 1 from public.accounting_third_party_identifiers
    where company_id=target_company_id and identifier=candidate and effective_until is null
  ) loop
    suffix:=suffix+1;
    candidate:=left(coalesce(nullif(base_identifier,''),'TIERS'),greatest(1,identifier_length-length(suffix::text)))||suffix::text;
  end loop;

  insert into public.accounting_third_party_identifiers(
    company_id,party_type,party_id,identifier,label,created_by
  ) values(
    target_company_id,target_party_type,target_party_id,candidate,
    coalesce(nullif(trim(target_label),''),'Tiers'),auth.uid()
  );
  return candidate;
end $$;

-- Cree les identifiants lisibles pour les tiers existants. Les profils
-- automatiques historiques ne sont pas reecrits : le moteur utilise le nouvel
-- identifiant, tandis qu'un code saisi manuellement reste prioritaire.
do $seed_readable_third_party_identifiers$
declare party_row record;
begin
  for party_row in
    select client.company_id,'client'::text party_type,client.id party_id,
      coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client') label
    from public.clients client
    union all
    select supplier.company_id,'supplier'::text,supplier.id,
      coalesce(nullif(trim(supplier.legal_name),''),'Fournisseur')
    from public.suppliers supplier
  loop
    perform public.ensure_accounting_third_party_identifier(
      party_row.company_id,party_row.party_type,party_row.party_id,party_row.label
    );
  end loop;
end $seed_readable_third_party_identifiers$;

-- Les lots deja valides conservent leur instantane original. Seules les
-- ecritures encore exportables sont recalees sur le nouveau modele.
update public.accounting_entry_lines line
set account_code='411',
    account_label='Client - '||coalesce(nullif(trim(line.auxiliary_label),''),'Client'),
    auxiliary_code=identifier.identifier
from public.accounting_entries entry
join public.accounting_third_party_identifiers identifier
  on identifier.company_id=entry.company_id
 and identifier.party_type='client'
 and identifier.effective_until is null
where line.entry_id=entry.id
  and line.third_party_id=identifier.party_id
  and (line.account_code='411000' or line.account_code='411')
  and not exists(
    select 1
    from public.accounting_export_batch_entries exported
    join public.accounting_export_batches batch on batch.id=exported.export_batch_id
    where exported.accounting_entry_id=entry.id and batch.status='validated'
  );

-- Les prochaines ecritures portent directement un libelle explicite.
do $accounting_customer_label_patch$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public._generate_document_accounting_entry(uuid)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    'select coalesce(profile.collective_account,settings.customer_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;',
    'select coalesce(profile.collective_account,settings.customer_collective_account),case when profile.assignment_mode=''manual'' then left(regexp_replace(upper(coalesce(profile.auxiliary_account,'''')),''[^A-Z0-9]'','''',''g''),10) else auxiliary end into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;'
  );
  patched_definition:=replace(
    patched_definition,
    'select coalesce(profile.collective_account,settings.supplier_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.supplier_accounting_profiles profile where profile.supplier_id=doc.supplier_id;',
    'select coalesce(profile.collective_account,settings.supplier_collective_account),case when profile.assignment_mode=''manual'' then left(regexp_replace(upper(coalesce(profile.auxiliary_account,'''')),''[^A-Z0-9]'','''',''g''),10) else auxiliary end into collective,auxiliary from public.supplier_accounting_profiles profile where profile.supplier_id=doc.supplier_id;'
  );
  patched_definition:=replace(
    patched_definition,
    'collective:=coalesce(collective,settings.customer_collective_account);',
    'collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '    auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,''client'',doc.client_id,party_label));'
  );
  patched_definition:=replace(
    patched_definition,
    'collective:=coalesce(collective,settings.supplier_collective_account);',
    'collective:=coalesce(collective,settings.supplier_collective_account);'||chr(10)||
    '    auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,''supplier'',doc.supplier_id,party_label));'
  );
  patched_definition:=replace(
    patched_definition,
    'values(doc.company_id,entry_id,line_no,collective,party_label,auxiliary,party_label,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,''Document''),',
    'values(doc.company_id,entry_id,line_no,collective,case when direction=''sale'' then ''Client - '' else ''Fournisseur - '' end||party_label,auxiliary,party_label,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,''Document''),'
  );
  if patched_definition=source_definition then
    raise exception 'accounting_customer_label_patch_not_applied';
  end if;
  execute patched_definition;
end $accounting_customer_label_patch$;

-- Sans profil comptable specifique, SELECT INTO remettait l'auxiliaire a
-- NULL dans les ecritures de reglement. Le repli automatique reste applique.
do $accounting_payment_auxiliary_patch$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public._generate_payment_accounting_entry(public.payments)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    'select coalesce(profile.collective_account,settings.customer_collective_account),coalesce(profile.auxiliary_account,auxiliary) into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;',
    'select coalesce(profile.collective_account,settings.customer_collective_account),case when profile.assignment_mode=''manual'' then left(regexp_replace(upper(coalesce(profile.auxiliary_account,'''')),''[^A-Z0-9]'','''',''g''),10) else auxiliary end into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;'
  );
  patched_definition:=replace(
    patched_definition,
    'collective:=coalesce(collective,settings.customer_collective_account);financial:=',
    'collective:=case when coalesce(collective,settings.customer_collective_account)=''411000'' then ''411'' else coalesce(collective,settings.customer_collective_account) end;'||chr(10)||
    '  auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(target_payment.company_id,''client'',doc.client_id,party_label));financial:='
  );
  if patched_definition=source_definition then
    raise exception 'accounting_payment_auxiliary_patch_not_applied';
  end if;
  execute patched_definition;
end $accounting_payment_auxiliary_patch$;

create or replace function public.preview_accounting_export(
  target_company_id uuid,
  target_journal_type text,
  target_starts_on date,
  target_ends_on date,
  target_format_key text,
  target_include_corrections boolean default true
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  report jsonb;
  entries jsonb;
  accounts jsonb;
  pieces integer;
  debit numeric;
  credit numeric;
  adapter record;
  auxiliary_max_length integer:=10;
begin
  if not public.has_company_permission(target_company_id,'accounting_export_preview') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_ends_on<target_starts_on then raise exception 'invalid_period';end if;
  select * into adapter from public.accounting_export_adapters where adapter_key=target_format_key;
  if adapter.id is null then raise exception 'unknown_export_adapter';end if;
  if adapter.availability<>'available' then raise exception 'export_adapter_not_verified';end if;

  select least(10,greatest(1,coalesce(auxiliary_length,10)))
  into auxiliary_max_length
  from public.accounting_settings where company_id=target_company_id;
  auxiliary_max_length:=coalesce(auxiliary_max_length,10);
  report:=public.validate_accounting_configuration(target_company_id);

  select
    coalesce(jsonb_agg(entry_payload order by entry_date,entry_number),'[]'::jsonb),
    count(distinct piece_reference),coalesce(sum(entry_debit),0),coalesce(sum(entry_credit),0)
  into entries,pieces,debit,credit
  from (
    select entry.entry_date,entry.entry_number,entry.piece_reference,entry.label,entry.currency,entry.id,
      coalesce(sum(line.debit),0) entry_debit,coalesce(sum(line.credit),0) entry_credit,
      jsonb_build_object(
        'id',entry.id,'entry_number',entry.entry_number,'entry_date',entry.entry_date,
        'piece_reference',entry.piece_reference,'piece_date',entry.piece_date,
        'label',entry.label,'journal_code',journal.code,'journal_label',journal.label,
        'document_id',entry.document_id,'payment_id',entry.payment_id,
        'debit',sum(line.debit),'credit',sum(line.credit),
        'balanced',abs(sum(line.debit)-sum(line.credit))<=0.01,
        'lines',jsonb_agg(jsonb_build_object(
          'account_code',line.account_code,
          'account_label',line.account_label,
          'auxiliary_code',line.auxiliary_code,
          'auxiliary_label',line.auxiliary_label,
          'combined_account_code',case
            when nullif(trim(coalesce(line.auxiliary_code,'')),'') is null then line.account_code
            else line.account_code||line.auxiliary_code
          end,
          'line_label',line.line_label,'debit',line.debit,'credit',line.credit,
          'tax_rate',line.tax_rate
        ) order by line.line_number)
      ) entry_payload
    from public.accounting_entries entry
    join public.accounting_journals journal on journal.id=entry.journal_id
    join public.accounting_entry_lines line on line.entry_id=entry.id
    where entry.company_id=target_company_id
      and entry.entry_date between target_starts_on and target_ends_on
      and (target_journal_type='fec' or journal.journal_type=target_journal_type)
      and (target_include_corrections or entry.status<>'corrective')
      and not exists(
        select 1 from public.accounting_export_batch_entries exported
        join public.accounting_export_batches batch on batch.id=exported.export_batch_id
        where exported.accounting_entry_id=entry.id and batch.status='validated'
      )
    group by entry.id,journal.code,journal.label
  ) payload;

  select coalesce(jsonb_agg(value order by account_code),'[]'::jsonb)
  into accounts
  from (
    select line.account_code,jsonb_build_object(
      'account_code',line.account_code,'account_label',max(line.account_label),
      'debit',sum(line.debit),'credit',sum(line.credit),'line_count',count(*),
      'auxiliaries',coalesce(jsonb_agg(distinct line.auxiliary_code)
        filter(where line.auxiliary_code is not null),'[]'::jsonb)
    ) value
    from public.accounting_entry_lines line
    join public.accounting_entries entry on entry.id=line.entry_id
    join public.accounting_journals journal on journal.id=entry.journal_id
    where entry.company_id=target_company_id
      and entry.entry_date between target_starts_on and target_ends_on
      and (target_journal_type='fec' or journal.journal_type=target_journal_type)
      and (target_include_corrections or entry.status<>'corrective')
      and not exists(
        select 1 from public.accounting_export_batch_entries exported
        join public.accounting_export_batches batch on batch.id=exported.export_batch_id
        where exported.accounting_entry_id=entry.id and batch.status='validated'
      )
    group by line.account_code
  ) summary;

  return jsonb_build_object(
    'ok',(report->>'ok')::boolean and abs(debit-credit)<=0.01,
    'journal_type',target_journal_type,'starts_on',target_starts_on,'ends_on',target_ends_on,
    'format',target_format_key,'adapter_status',adapter.availability,
    'piece_count',pieces,'entry_count',jsonb_array_length(entries),
    'total_debit',round(debit,2),'total_credit',round(credit,2),
    'auxiliary_max_length',auxiliary_max_length,
    'accounts',accounts,'entries',entries,'configuration',report,
    'fec_status',case when target_format_key='fec_technical' then 'Revue comptable requise' else null end
  );
end $$;

alter table public.company_fiscal_configurations
  alter column schema_version set default '202607270086';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.40',schema_version='202607270086',updated_at=now()
where application_version is distinct from '0.9.0-compliance.40'
   or schema_version is distinct from '202607270086';

commit;
