begin;

-- Une seule source de vérité pour la numérotation commerciale.
alter table public.company_document_settings add column if not exists quote_number_format text not null default 'prefix_year_month';
alter table public.company_document_settings add column if not exists invoice_number_format text not null default 'prefix_year_month';
alter table public.company_document_settings add column if not exists numbering_configured_at timestamptz;

alter table public.company_document_settings drop constraint if exists company_document_settings_quote_number_format_check;
alter table public.company_document_settings add constraint company_document_settings_quote_number_format_check
  check(quote_number_format in('prefix_year_month','prefix_year','year_prefix')) not valid;
alter table public.company_document_settings drop constraint if exists company_document_settings_invoice_number_format_check;
alter table public.company_document_settings add constraint company_document_settings_invoice_number_format_check
  check(invoice_number_format in('prefix_year_month','prefix_year','year_prefix')) not valid;

create or replace function public.save_company_numbering_configuration(
  target_company_id uuid,
  target_quote_prefix text,
  target_quote_next_number integer,
  target_quote_format text,
  target_invoice_prefix text,
  target_invoice_next_number integer,
  target_invoice_format text,
  target_credit_prefix text,
  target_quote_validity_days integer
) returns public.company_document_settings
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  current_settings public.company_document_settings%rowtype;
  result public.company_document_settings%rowtype;
  has_quote boolean;
  has_invoice boolean;
  target_year integer:=extract(year from current_date)::integer;
begin
  if not public.has_company_permission(target_company_id,'company.settings.manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if coalesce(target_quote_next_number,0)<1 or coalesce(target_invoice_next_number,0)<1 then
    raise exception 'document_start_number_invalid' using errcode='22023';
  end if;
  if target_quote_format not in('prefix_year_month','prefix_year','year_prefix')
     or target_invoice_format not in('prefix_year_month','prefix_year','year_prefix') then
    raise exception 'document_number_format_invalid' using errcode='22023';
  end if;
  if upper(trim(coalesce(target_quote_prefix,'')))!~'^[A-Z0-9]{1,10}$'
     or upper(trim(coalesce(target_invoice_prefix,'')))!~'^[A-Z0-9]{1,10}$'
     or upper(trim(coalesce(target_credit_prefix,'')))!~'^[A-Z0-9]{1,10}$' then
    raise exception 'document_prefix_invalid' using errcode='22023';
  end if;

  insert into public.company_document_settings(company_id) values(target_company_id) on conflict(company_id) do nothing;
  select * into current_settings from public.company_document_settings where company_id=target_company_id for update;
  select exists(select 1 from public.documents where company_id=target_company_id and document_type='quote') into has_quote;
  select exists(select 1 from public.documents where company_id=target_company_id and document_type in('invoice','deposit_invoice','balance_invoice','credit_note')) into has_invoice;

  if has_quote and (current_settings.quote_prefix is distinct from upper(trim(target_quote_prefix))
     or current_settings.quote_next_number is distinct from target_quote_next_number
     or current_settings.quote_number_format is distinct from target_quote_format) then
    raise exception 'quote_numbering_locked' using errcode='55000';
  end if;
  if has_invoice and (current_settings.invoice_prefix is distinct from upper(trim(target_invoice_prefix))
     or current_settings.invoice_next_number is distinct from target_invoice_next_number
     or current_settings.invoice_number_format is distinct from target_invoice_format) then
    raise exception 'invoice_numbering_locked' using errcode='55000';
  end if;

  update public.company_document_settings set
    quote_prefix=upper(trim(target_quote_prefix)),quote_next_number=target_quote_next_number,quote_number_format=target_quote_format,
    invoice_prefix=upper(trim(target_invoice_prefix)),invoice_next_number=target_invoice_next_number,invoice_number_format=target_invoice_format,
    credit_prefix=upper(trim(target_credit_prefix)),quote_validity_days=greatest(1,coalesce(target_quote_validity_days,30)),
    numbering_configured_at=coalesce(numbering_configured_at,now()),updated_at=now()
  where company_id=target_company_id returning * into result;

  if not has_quote then
    insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
    values(target_company_id,public._piloz_document_sequence_key('quote'),result.quote_prefix,target_year,result.quote_next_number,4,auth.uid())
    on conflict(company_id,document_type,year) do update set prefix=excluded.prefix,next_value=excluded.next_value,padding=excluded.padding,updated_at=now();
  end if;
  if not has_invoice then
    insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
    values(target_company_id,public._piloz_document_sequence_key('invoice'),result.invoice_prefix,target_year,result.invoice_next_number,4,auth.uid())
    on conflict(company_id,document_type,year) do update set prefix=excluded.prefix,next_value=excluded.next_value,padding=excluded.padding,updated_at=now();
  end if;
  return result;
end $$;

create or replace function public._piloz_take_document_number(
  target_company_id uuid,target_type text,target_year integer,is_draft boolean default false
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare
  sequence_key text;sequence_row public.document_sequences%rowtype;desired_prefix text;
  configured_next integer:=1;number_format text:='prefix_year_month';number_value text;target_month text;
begin
  if target_company_id is null or target_year not between 2000 and 2200 then raise exception 'invalid_document_sequence';end if;
  sequence_key:=case when is_draft then 'draft:' else '' end||public._piloz_document_sequence_key(target_type);
  desired_prefix:=public._piloz_document_prefix(target_company_id,target_type,is_draft);
  if not is_draft then
    select case when target_type='quote' then quote_next_number when target_type in('invoice','deposit_invoice','balance_invoice') then invoice_next_number else 1 end,
           case when target_type='quote' then quote_number_format when target_type in('invoice','deposit_invoice','balance_invoice') then invoice_number_format else 'prefix_year' end
    into configured_next,number_format from public.company_document_settings where company_id=target_company_id;
  end if;
  insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
  values(target_company_id,sequence_key,desired_prefix,target_year,greatest(1,coalesce(configured_next,1)),4,coalesce(auth.uid(),(select owner_user_id from public.companies where id=target_company_id)))
  on conflict(company_id,document_type,year) do nothing;
  select * into sequence_row from public.document_sequences where company_id=target_company_id and document_type=sequence_key and year=target_year for update;
  if sequence_row.id is null then raise exception 'document_sequence_unavailable';end if;
  if sequence_row.next_value=greatest(1,coalesce(configured_next,1)) and sequence_row.prefix is distinct from desired_prefix then
    update public.document_sequences set prefix=desired_prefix,updated_at=now() where id=sequence_row.id returning * into sequence_row;
  end if;
  update public.document_sequences set next_value=next_value+1,updated_at=now() where id=sequence_row.id;
  if not is_draft then
    update public.company_document_settings set
      quote_next_number=case when target_type='quote' then sequence_row.next_value+1 else quote_next_number end,
      invoice_next_number=case when target_type in('invoice','deposit_invoice','balance_invoice') then sequence_row.next_value+1 else invoice_next_number end,
      updated_at=now() where company_id=target_company_id;
  end if;
  number_value:=lpad(sequence_row.next_value::text,sequence_row.padding,'0');
  target_month:=lpad(extract(month from current_date)::integer::text,2,'0');
  return case number_format
    when 'prefix_year_month' then sequence_row.prefix||'-'||target_year||'-'||target_month||'-'||number_value
    when 'year_prefix' then target_year||'-'||sequence_row.prefix||'-'||number_value
    else sequence_row.prefix||'-'||target_year||'-'||number_value end;
end $$;

-- Identifiants auxiliaires configurables : 10 caractères restent la valeur par défaut.
alter table public.accounting_settings drop constraint if exists accounting_settings_auxiliary_length_check;
alter table public.accounting_settings add constraint accounting_settings_auxiliary_length_check check(auxiliary_length between 4 and 20) not valid;
alter table public.accounting_third_party_identifiers drop constraint if exists accounting_third_party_identifiers_identifier_check;
alter table public.accounting_third_party_identifiers add constraint accounting_third_party_identifiers_identifier_check check(identifier~'^[A-Z0-9_]{4,20}$') not valid;

-- Les deux méthodes d'acompte exposées sont l'attente et l'imputation directe.
update public.accounting_settings set deposit_method='suspense' where deposit_method='dedicated';

-- Profils de vente par type utilisés directement par le moteur d'écritures.
create index if not exists item_accounting_profiles_company_type_idx
  on public.item_accounting_profiles(company_id,item_type) where item_id is null and category_id is null and item_type is not null;

create or replace function public.sync_accounting_mapping_to_engine()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare profile_id uuid;
begin
  if new.scope_type='global' then
    update public.accounting_settings set
      default_sales_account=case when new.direction='sale' then new.account_code else default_sales_account end,
      default_purchase_account=case when new.direction='purchase' then new.account_code else default_purchase_account end,
      updated_at=now() where company_id=new.company_id;
  elsif new.scope_type='item_type' then
    select id into profile_id from public.item_accounting_profiles
      where company_id=new.company_id and item_id is null and category_id is null and item_type=new.scope_value limit 1;
    if profile_id is null then
      insert into public.item_accounting_profiles(company_id,item_type,sales_account_code,purchase_account_code,is_active,created_by,updated_by)
      values(new.company_id,new.scope_value,case when new.direction='sale' then new.account_code end,case when new.direction='purchase' then new.account_code end,new.active,auth.uid(),auth.uid());
    else
      update public.item_accounting_profiles set
        sales_account_code=case when new.direction='sale' then new.account_code else sales_account_code end,
        purchase_account_code=case when new.direction='purchase' then new.account_code else purchase_account_code end,
        is_active=new.active,updated_by=auth.uid(),updated_at=now() where id=profile_id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists accounting_account_mappings_sync_engine on public.accounting_account_mappings;
create trigger accounting_account_mappings_sync_engine after insert or update of account_code,active,scope_type,scope_value
on public.accounting_account_mappings for each row execute function public.sync_accounting_mapping_to_engine();

-- Un taux ajouté en comptabilité devient immédiatement sélectionnable dans les documents.
create or replace function public.sync_accounting_vat_rate_to_documents()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare rate_id uuid;rate_label text;
begin
  rate_label:=case new.tax_rate when 0 then 'Exonéré' when 2.1 then 'Taux particulier' when 5.5 then 'Taux réduit' when 8.5 then 'Taux DOM-TOM' when 10 then 'Taux intermédiaire' when 20 then 'Taux normal' else 'TVA '||trim(to_char(new.tax_rate,'FM999990D999'))||' %' end;
  select id into rate_id from public.vat_rates where company_id=new.company_id and rate=new.tax_rate order by active desc,created_at desc limit 1;
  if rate_id is null then
    insert into public.vat_rates(company_id,rate,label,account_code,valid_from,active,created_by)
    values(new.company_id,new.tax_rate,rate_label,new.sales_account,new.effective_from,new.active,auth.uid());
  else
    update public.vat_rates set label=rate_label,account_code=new.sales_account,active=new.active,updated_at=now() where id=rate_id;
  end if;
  return new;
end $$;
drop trigger if exists accounting_vat_mappings_sync_documents on public.accounting_vat_mappings;
create trigger accounting_vat_mappings_sync_documents after insert or update of tax_rate,sales_account,active
on public.accounting_vat_mappings for each row execute function public.sync_accounting_vat_rate_to_documents();

-- Valeurs par défaut demandées pour toutes les entreprises existantes.
do $$ declare company_row record;item_kind text;vat_row record;payment_kind text;begin
  for company_row in select id from public.companies loop
    perform public._bootstrap_company_accounting(company_row.id,current_date);
    insert into public.accounting_vat_mappings(company_id,tax_rate,purchase_account,sales_account,suspense_account,sale_account_extension,purchase_account_extension,effective_from)
    values(company_row.id,0,null,null,null,'3','3',make_date(extract(year from current_date)::integer,1,1))
    on conflict(company_id,tax_rate,effective_from) do nothing;
    for vat_row in select * from (values
      (0::numeric,'3'),(2.1::numeric,'004'),(5.5::numeric,'001'),(8.5::numeric,'005'),(10::numeric,'003'),(20::numeric,'002')
    ) configured(rate,extension) loop
      insert into public.accounting_vat_mappings(company_id,tax_rate,sale_account_extension,purchase_account_extension,effective_from)
      values(company_row.id,vat_row.rate,vat_row.extension,vat_row.extension,make_date(extract(year from current_date)::integer,1,1))
      on conflict(company_id,tax_rate,effective_from) do update set
        sale_account_extension=coalesce(public.accounting_vat_mappings.sale_account_extension,excluded.sale_account_extension),
        purchase_account_extension=coalesce(public.accounting_vat_mappings.purchase_account_extension,excluded.purchase_account_extension);
    end loop;
    for item_kind in select unnest(array['product','service','subscription','package','fee','discount','comment']) loop
      insert into public.accounting_account_mappings(company_id,direction,scope_type,scope_value,account_code,effective_from)
      values(company_row.id,'sale','item_type',item_kind,'701',make_date(extract(year from current_date)::integer,1,1))
      on conflict(company_id,direction,scope_type,scope_value,effective_from) do nothing;
    end loop;
    insert into public.accounting_financial_accounts(company_id,name,account_code,account_type,active)
    select company_row.id,'BANQUE PRINCIPALE','512100','bank',true
    where not exists(select 1 from public.accounting_financial_accounts where company_id=company_row.id and account_type='bank');
    for payment_kind in select unnest(array['bank_transfer','direct_debit','card','cheque','check','cash','paypal','other']) loop
      insert into public.accounting_payment_method_mappings(company_id,payment_method,financial_account_code,active)
      values(company_row.id,payment_kind,'512100',true)
      on conflict(company_id,payment_method) do nothing;
    end loop;
  end loop;
end $$;

-- Les nouvelles entreprises reçoivent exactement la même configuration.
create or replace function public.bootstrap_new_company_accounting()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare item_kind text;vat_row record;payment_kind text;
begin
  perform public._bootstrap_company_accounting(new.id,current_date);
  update public.accounting_settings set default_sales_account='701',updated_at=now()
    where company_id=new.id and default_sales_account in('706','706000');
  for item_kind in select unnest(array['product','service','subscription','package','fee','discount','comment']) loop
    insert into public.accounting_account_mappings(company_id,direction,scope_type,scope_value,account_code,effective_from)
    values(new.id,'sale','item_type',item_kind,'701',make_date(extract(year from current_date)::integer,1,1))
    on conflict(company_id,direction,scope_type,scope_value,effective_from) do nothing;
  end loop;
  for vat_row in select * from (values
    (0::numeric,'3'),(2.1::numeric,'004'),(5.5::numeric,'001'),(8.5::numeric,'005'),(10::numeric,'003'),(20::numeric,'002')
  ) configured(rate,extension) loop
    insert into public.accounting_vat_mappings(company_id,tax_rate,sale_account_extension,purchase_account_extension,effective_from)
    values(new.id,vat_row.rate,vat_row.extension,vat_row.extension,make_date(extract(year from current_date)::integer,1,1))
    on conflict(company_id,tax_rate,effective_from) do update set
      sale_account_extension=coalesce(public.accounting_vat_mappings.sale_account_extension,excluded.sale_account_extension),
      purchase_account_extension=coalesce(public.accounting_vat_mappings.purchase_account_extension,excluded.purchase_account_extension);
  end loop;
  insert into public.accounting_financial_accounts(company_id,name,account_code,account_type,active)
    select new.id,'BANQUE PRINCIPALE','512100','bank',true
    where not exists(select 1 from public.accounting_financial_accounts where company_id=new.id and account_type='bank');
  for payment_kind in select unnest(array['bank_transfer','direct_debit','card','cheque','check','cash','paypal','other']) loop
    insert into public.accounting_payment_method_mappings(company_id,payment_method,financial_account_code,active)
    values(new.id,payment_kind,'512100',true)
    on conflict(company_id,payment_method) do nothing;
  end loop;
  return new;
end $$;

update public.accounting_settings set default_sales_account='701',updated_at=now()
where default_sales_account in('706','706000');

-- Index couvrants des écrans les plus consultés : documents, TVA et comptabilité.
create index if not exists documents_company_type_issue_idx
  on public.documents(company_id,document_type,issue_date desc,created_at desc);
create index if not exists document_lines_document_position_idx
  on public.document_lines(document_id,position,created_at);
create index if not exists vat_rates_company_active_rate_idx
  on public.vat_rates(company_id,active,rate);
create index if not exists accounting_account_mappings_company_direction_idx
  on public.accounting_account_mappings(company_id,direction,active,scope_type);
create index if not exists accounting_vat_mappings_company_rate_idx
  on public.accounting_vat_mappings(company_id,active,tax_rate,effective_from desc);

alter table public.company_fiscal_configurations alter column schema_version set default '202607260083';
update public.company_fiscal_configurations set
  application_version='0.9.0-compliance.34',schema_version='202607260083',updated_at=now()
where application_version is distinct from '0.9.0-compliance.34'
   or schema_version is distinct from '202607260083';

-- Déclenche les synchronisations sur les lignes historiques sans modifier leur valeur métier.
update public.accounting_account_mappings set account_code=account_code;
update public.accounting_vat_mappings set tax_rate=tax_rate;

-- La longueur choisie pour les auxiliaires est réellement appliquée par le générateur.
create or replace function public.ensure_accounting_third_party_identifier(
  target_company_id uuid,target_party_type text,target_party_id uuid,target_label text
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare candidate text;sequence integer:=0;existing text;identifier_length integer:=10;padding text:='_';base text;
begin
  select identifier into existing from public.accounting_third_party_identifiers
    where company_id=target_company_id and party_type=target_party_type and party_id=target_party_id and effective_until is null;
  if existing is not null then return existing;end if;
  select auxiliary_length,auxiliary_padding_character into identifier_length,padding
    from public.accounting_settings where company_id=target_company_id;
  identifier_length:=least(20,greatest(4,coalesce(identifier_length,10)));
  padding:=coalesce(nullif(left(padding,1),''),'_');
  base:=regexp_replace(translate(upper(coalesce(target_label,'')),
    'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝŸŒÆ','AAAAAACEEEEIIIINOOOOOUUUUYYOA'),
    '[^A-Z0-9]','','g');
  candidate:=rpad(left(coalesce(nullif(base,''),'TIERS'),identifier_length),identifier_length,padding);
  while exists(select 1 from public.accounting_third_party_identifiers where company_id=target_company_id and identifier=candidate and effective_until is null) loop
    sequence:=sequence+1;
    candidate:=rpad(left(coalesce(nullif(base,''),'TIERS'),greatest(1,identifier_length-length(sequence::text)))||sequence::text,identifier_length,padding);
  end loop;
  insert into public.accounting_third_party_identifiers(company_id,party_type,party_id,identifier,label,created_by)
  values(target_company_id,target_party_type,target_party_id,candidate,coalesce(nullif(trim(target_label),''),'Tiers'),auth.uid());
  return candidate;
end $$;

-- Corrige le choix des comptes par sens et la méthode d'acompte dans le moteur existant.
do $accounting_patch$ declare source_definition text;patched_definition text;begin
  select pg_get_functiondef('public._generate_document_accounting_entry(uuid)'::regprocedure) into source_definition;
  patched_definition:=replace(source_definition,
$$select profile_code into account_code from (
      select profile.sales_account_code profile_code,1 rank from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.item_id=line_row.item_id and profile.is_active
      union all select profile.purchase_account_code,1 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.item_id=line_row.item_id and profile.is_active
      union all select profile.sales_account_code,2 from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.category_id=line_row.category_id and profile.is_active
      union all select profile.purchase_account_code,2 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.category_id=line_row.category_id and profile.is_active
      union all select profile.sales_account_code,3 from public.item_accounting_profiles profile where direction='sale' and profile.company_id=doc.company_id and profile.item_type=line_row.item_type and profile.is_active
      union all select profile.purchase_account_code,3 from public.item_accounting_profiles profile where direction='purchase' and profile.company_id=doc.company_id and profile.item_type=line_row.item_type and profile.is_active
    ) resolved where profile_code is not null order by rank limit 1;$$,
$$select case when direction='sale' then profile.sales_account_code else profile.purchase_account_code end into account_code
    from public.item_accounting_profiles profile
    where profile.company_id=doc.company_id and profile.is_active
      and (profile.item_id=line_row.item_id or profile.category_id=line_row.category_id or profile.item_type=line_row.item_type)
    order by (profile.item_id is not null) desc,(profile.category_id is not null) desc,(profile.item_type is not null) desc,profile.priority desc limit 1;$$);
  patched_definition:=replace(patched_definition,
    $$case when direction='sale' then settings.deposit_account else settings.default_purchase_account end,$$,
    $$case when direction='sale' then case when settings.deposit_method='direct' then settings.default_sales_account else settings.deposit_account end else settings.default_purchase_account end,$$);
  if patched_definition=source_definition then raise exception 'accounting_engine_patch_not_applied';end if;
  execute patched_definition;
end $accounting_patch$;

create or replace function public.backfill_company_accounting_entries(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc_row record;created_count integer:=0;failure_count integer:=0;
begin
  if not public.has_company_permission(target_company_id,'accounting.entries.read') then raise exception 'forbidden' using errcode='42501';end if;
  for doc_row in select document.id from public.documents document
    where document.company_id=target_company_id and document.finalized_at is not null
      and document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice')
      and not exists(select 1 from public.accounting_entries entry where entry.company_id=target_company_id and entry.source_type='document' and entry.source_id=document.id)
    order by document.issue_date,document.created_at
  loop
    begin perform public._generate_document_accounting_entry(doc_row.id);created_count:=created_count+1;
    exception when others then failure_count:=failure_count+1;end;
  end loop;
  return jsonb_build_object('created',created_count,'failed',failure_count);
end $$;

revoke all on function public.save_company_numbering_configuration(uuid,text,integer,text,text,integer,text,text,integer),public.backfill_company_accounting_entries(uuid) from public,anon;
grant execute on function public.save_company_numbering_configuration(uuid,text,integer,text,text,integer,text,text,integer),public.backfill_company_accounting_entries(uuid) to authenticated;

commit;
