begin;

-- Le libelle metier "Main d'oeuvre" reutilise volontairement la cle technique
-- historique `service`. Cette compatibilite preserve les documents, API et
-- integrations existants sans creer un second moteur de catalogue.
create or replace function public.canonical_catalog_item_type(target_item_type text)
returns text language sql immutable set search_path=public,pg_temp as $$
  with normalized as (
    select regexp_replace(
      translate(
        replace(lower(trim(coalesce(target_item_type,''))),'œ','oe'),
        'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ',
        'aaaaaaceeeeiiiinooooouuuuyy'
      ),
      '[^a-z0-9]+','','g'
    ) value
  )
  select case value
    when 'product' then 'product'
    when 'products' then 'product'
    when 'article' then 'product'
    when 'articles' then 'product'
    when 'service' then 'service'
    when 'services' then 'service'
    when 'labor' then 'service'
    when 'labour' then 'service'
    when 'mainoeuvre' then 'service'
    when 'maindoeuvre' then 'service'
    when 'subscription' then 'subscription'
    when 'subscriptions' then 'subscription'
    when 'abonnement' then 'subscription'
    when 'abonnements' then 'subscription'
    when 'fee' then 'fee'
    when 'fees' then 'fee'
    when 'frais' then 'fee'
    else null
  end
  from normalized
$$;

create or replace function public.sales_account_type_label(target_item_type text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case public.canonical_catalog_item_type(target_item_type)
    when 'product' then 'Article'
    when 'service' then 'Main d’œuvre'
    when 'subscription' then 'Abonnement'
    when 'fee' then 'Frais'
    else coalesce(target_item_type,'Type inconnu')
  end
$$;

create or replace function public.resolve_sales_account_code(
  target_company_id uuid,target_item_type text,target_effective_on date default current_date
) returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare resolved_code text;canonical_type text;
begin
  canonical_type:=public.canonical_catalog_item_type(target_item_type);
  if canonical_type is null then
    raise exception 'accounting_sales_type_invalid:%',coalesce(target_item_type,'null') using errcode='22023';
  end if;
  select mapping.account_code into resolved_code
  from public.accounting_account_mappings mapping
  where mapping.company_id=target_company_id
    and mapping.direction='sale'
    and mapping.scope_type='item_type'
    and mapping.scope_value=canonical_type
    and mapping.active
    and mapping.effective_from<=coalesce(target_effective_on,current_date)
  order by mapping.effective_from desc,mapping.updated_at desc,mapping.id desc
  limit 1;
  if resolved_code is null then
    raise exception 'accounting_sales_account_missing:%',public.sales_account_type_label(canonical_type)
      using errcode='23514';
  end if;
  return resolved_code;
end
$$;

-- L'API accepte aussi le libelle metier francais. La cle stockee reste
-- `service`, afin de conserver la compatibilite avec les donnees existantes.
create or replace function public.next_catalog_reference(target_company_id uuid,target_item_type text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare settings public.company_catalog_settings%rowtype; next_value bigint; prefix text; result text; canonical_type text;
begin
  if auth.uid() is null or not public.can_manage_catalog(target_company_id,'catalog_create') then raise exception 'forbidden' using errcode='42501'; end if;
  canonical_type:=public.canonical_catalog_item_type(target_item_type);
  if canonical_type is null then raise exception 'catalog_item_type_not_selectable:%',coalesce(target_item_type,'null') using errcode='22023'; end if;
  insert into public.company_catalog_settings(company_id,created_by) values(target_company_id,auth.uid()) on conflict(company_id) do nothing;
  select * into settings from public.company_catalog_settings where company_id=target_company_id for update;
  if canonical_type='service' then next_value:=settings.service_next_number;prefix:=settings.service_prefix;
    update public.company_catalog_settings set service_next_number=service_next_number+1,updated_by=auth.uid(),updated_at=now() where company_id=target_company_id;
  else next_value:=settings.product_next_number;prefix:=settings.product_prefix;
    update public.company_catalog_settings set product_next_number=product_next_number+1,updated_by=auth.uid(),updated_at=now() where company_id=target_company_id;
  end if;
  result:=replace(replace(settings.reference_format,'{PREFIX}',prefix),'{NUMBER}',lpad(next_value::text,settings.reference_padding,'0'));
  return result;
end
$$;

revoke all on function public.next_catalog_reference(uuid,text) from public,anon;
grant execute on function public.next_catalog_reference(uuid,text) to authenticated;

create or replace function public.assert_sales_account_type_mappings(target_company_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare report jsonb;labels text;
begin
  report:=public.validate_sales_account_type_mappings(target_company_id);
  if not coalesce((report->>'ok')::boolean,false) then
    select string_agg(value->>'label',', ') into labels from jsonb_array_elements(report->'missing');
    raise exception 'accounting_sales_accounts_missing:%',coalesce(labels,'Article, Main d’œuvre, Abonnement, Frais') using errcode='23514';
  end if;
end
$$;

-- Les anciennes lignes restent consultables. La contrainte NOT VALID protege
-- toutes les nouvelles ecritures sans invalider les packs historiques.
alter table public.catalog_items drop constraint if exists catalog_items_item_type_check;
alter table public.catalog_items add constraint catalog_items_item_type_check
  check(item_type in('product','service','subscription','fee')) not valid;

create or replace function public.enforce_catalog_item_business_type()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare canonical_type text;
begin
  if tg_op='INSERT' or new.item_type is distinct from old.item_type then
    canonical_type:=public.canonical_catalog_item_type(new.item_type);
    if canonical_type is null then
      raise exception 'catalog_item_type_not_selectable:%',coalesce(new.item_type,'null') using errcode='23514';
    end if;
    new.item_type:=canonical_type;
    if canonical_type='service' then new.stock_managed:=false; end if;
  end if;
  return new;
end
$$;

drop trigger if exists catalog_items_enforce_business_type on public.catalog_items;
create trigger catalog_items_enforce_business_type
before insert or update of item_type on public.catalog_items
for each row execute function public.enforce_catalog_item_business_type();

-- Nettoyage uniquement du parametrage : aucune fiche, facture ou ligne
-- historique n'est supprimee.
delete from public.accounting_account_mappings
where direction='sale' and scope_type='item_type'
  and lower(scope_value) in('package','pack','kit','discount','remise','comment','commentaire');
delete from public.item_accounting_profiles
where item_id is null and category_id is null
  and lower(item_type) in('package','pack','kit','discount','remise','comment','commentaire');

do $seed_labor_sales_accounts$
declare company_row record;configured record;existing_id uuid;existing_code text;year_start date:=make_date(extract(year from current_date)::integer,1,1);
begin
  for company_row in select id from public.companies loop
    for configured in select * from (values
      ('product','707000'),('service','706000'),('subscription','706000'),('fee','708000')
    ) values_to_seed(item_type,default_account) loop
      select mapping.id,mapping.account_code into existing_id,existing_code
      from public.accounting_account_mappings mapping
      where mapping.company_id=company_row.id and mapping.direction='sale'
        and mapping.scope_type='item_type' and mapping.scope_value=configured.item_type
        and mapping.active
      order by mapping.effective_from desc,mapping.updated_at desc,mapping.id desc limit 1;
      if existing_id is null then
        insert into public.accounting_account_mappings(company_id,direction,scope_type,scope_value,account_code,effective_from,active)
        values(company_row.id,'sale','item_type',configured.item_type,configured.default_account,year_start,true);
      elsif nullif(trim(existing_code),'') is null or existing_code in('701','701000') then
        update public.accounting_account_mappings set account_code=configured.default_account,updated_at=now()
        where id=existing_id;
      end if;
    end loop;
  end loop;
end
$seed_labor_sales_accounts$;

comment on function public.canonical_catalog_item_type(text) is
  'Normalise les libelles API/catalogue vers product, service (Main d oeuvre), subscription ou fee.';
comment on function public.sales_account_type_label(text) is
  'Libelle utilisateur des quatre types comptables de vente Piloz.';

revoke all on function public.canonical_catalog_item_type(text) from public,anon;
grant execute on function public.canonical_catalog_item_type(text) to authenticated;

alter table public.company_fiscal_configurations alter column application_version set default '0.9.0-compliance.48';
alter table public.company_fiscal_configurations alter column schema_version set default '202607270093';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.48',schema_version='202607270093',updated_at=now()
where application_version is distinct from '0.9.0-compliance.48'
   or schema_version is distinct from '202607270093';

commit;
