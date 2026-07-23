begin;

-- Catalogue professionnel Piloz. Migration additive et non destructive.
-- Les anciennes lignes de catalogue et leurs liaisons conservent leurs identifiants.

alter table public.catalog_items drop constraint if exists catalog_items_item_type_check;
alter table public.catalog_items add constraint catalog_items_item_type_check
  check(item_type in('product','service','subscription','package','fee','discount','comment')) not valid;
alter table public.catalog_items add column if not exists status text not null default 'active';
alter table public.catalog_items add column if not exists detailed_description text;
alter table public.catalog_items add column if not exists internal_notes text;
alter table public.catalog_items add column if not exists aliases text[] not null default '{}';
alter table public.catalog_items add column if not exists manufacturer_reference text;
alter table public.catalog_items add column if not exists country_of_origin text;
alter table public.catalog_items add column if not exists customs_code text;
alter table public.catalog_items add column if not exists weight numeric(15,4);
alter table public.catalog_items add column if not exists length numeric(15,4);
alter table public.catalog_items add column if not exists width numeric(15,4);
alter table public.catalog_items add column if not exists height numeric(15,4);
alter table public.catalog_items add column if not exists volume numeric(15,4);
alter table public.catalog_items add column if not exists available_from date;
alter table public.catalog_items add column if not exists discontinued_at date;
alter table public.catalog_items add column if not exists track_lots boolean not null default false;
alter table public.catalog_items add column if not exists track_serials boolean not null default false;
alter table public.catalog_items add column if not exists billing_unit text;
alter table public.catalog_items add column if not exists estimated_duration_minutes integer;
alter table public.catalog_items add column if not exists minimum_billable_minutes integer;
alter table public.catalog_items add column if not exists billing_interval text;
alter table public.catalog_items add column if not exists recurring boolean not null default false;
alter table public.catalog_items add column if not exists updated_by uuid;
alter table public.catalog_items add column if not exists archived_at timestamptz;
alter table public.catalog_items drop constraint if exists catalog_items_status_check;
alter table public.catalog_items add constraint catalog_items_status_check
  check(status in('active','inactive','draft','discontinued','archived')) not valid;
update public.catalog_items set status=case when active then 'active' else 'inactive' end where status is null or status='active' and not active;

alter table public.catalog_categories add column if not exists position integer not null default 0;
alter table public.catalog_categories add column if not exists color text not null default '#E7F5F3';
alter table public.catalog_categories add column if not exists default_unit text;
alter table public.catalog_categories add column if not exists default_tax_rate numeric(5,2);
alter table public.catalog_categories add column if not exists default_margin_rate numeric(9,4);
alter table public.catalog_categories add column if not exists default_supplier_id uuid references public.suppliers(id) on delete set null;
alter table public.catalog_categories add column if not exists default_stock_managed boolean;
alter table public.catalog_categories add column if not exists accounting_code text;

alter table public.supplier_items add column if not exists supplier_designation text;
alter table public.supplier_items add column if not exists currency text not null default 'EUR';
alter table public.supplier_items add column if not exists discount_rate numeric(7,4) not null default 0;
alter table public.supplier_items add column if not exists approach_fees numeric(15,4) not null default 0;
alter table public.supplier_items add column if not exists price_updated_at timestamptz;
alter table public.supplier_items add column if not exists valid_from date;
alter table public.supplier_items add column if not exists valid_until date;
alter table public.supplier_items add column if not exists active boolean not null default true;
create unique index if not exists supplier_items_one_primary_idx on public.supplier_items(catalog_item_id) where is_primary and active;

alter table public.stock_movements add column if not exists variant_id uuid;
alter table public.stock_movements add column if not exists transfer_group_id uuid;
alter table public.stock_movements add column if not exists lot_number text;
alter table public.stock_movements add column if not exists serial_number text;
alter table public.stock_reservations add column if not exists variant_id uuid;
alter table public.attachments add column if not exists visibility text not null default 'internal';
alter table public.attachments add column if not exists attachment_kind text not null default 'internal_document';
alter table public.attachments drop constraint if exists attachments_visibility_check;
alter table public.attachments add constraint attachments_visibility_check check(visibility in('internal','client')) not valid;

create table if not exists public.company_catalog_settings(
  company_id uuid primary key references public.companies(id) on delete cascade,
  product_prefix text not null default 'ART', service_prefix text not null default 'SER',
  reference_padding integer not null default 6 check(reference_padding between 2 and 12),
  product_next_number bigint not null default 1, service_next_number bigint not null default 1,
  reference_format text not null default '{PREFIX}-{NUMBER}', auto_reference boolean not null default true,
  manual_reference_allowed boolean not null default true, reserve_on_quote boolean not null default false,
  reserve_on_order boolean not null default true, allow_negative_stock boolean not null default false,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.item_tags(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, color text not null default '#E7F5F3', is_active boolean not null default true,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,name)
);
create table if not exists public.item_tag_assignments(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete cascade,
  tag_id uuid not null references public.item_tags(id) on delete cascade,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), unique(item_id,tag_id)
);

create table if not exists public.item_variant_attributes(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete cascade,
  name text not null, values text[] not null default '{}', position integer not null default 0,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(item_id,name)
);
create table if not exists public.item_variants(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete cascade,
  name text not null, reference text not null, barcode text, attribute_values jsonb not null default '{}'::jsonb,
  purchase_price numeric(15,4), cost_price numeric(15,4), sale_price numeric(15,4), tax_rate numeric(5,2),
  weight numeric(15,4), image_path text, minimum_stock numeric(15,4) not null default 0,
  supplier_id uuid references public.suppliers(id) on delete set null, status text not null default 'active', is_active boolean not null default true,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,reference), unique(item_id,attribute_values)
);
alter table public.stock_movements drop constraint if exists stock_movements_variant_id_fkey;
alter table public.stock_movements add constraint stock_movements_variant_id_fkey foreign key(variant_id) references public.item_variants(id) on delete restrict;
alter table public.stock_reservations drop constraint if exists stock_reservations_variant_id_fkey;
alter table public.stock_reservations add constraint stock_reservations_variant_id_fkey foreign key(variant_id) references public.item_variants(id) on delete restrict;

create table if not exists public.item_price_history(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete restrict,
  variant_id uuid references public.item_variants(id) on delete restrict,
  old_purchase_price numeric(15,4), new_purchase_price numeric(15,4), old_landing_cost numeric(15,4), new_landing_cost numeric(15,4),
  old_cost_price numeric(15,4), new_cost_price numeric(15,4), old_sale_price numeric(15,4), new_sale_price numeric(15,4),
  old_margin numeric(15,4), new_margin numeric(15,4), effective_from date not null default current_date,
  reason text, source text not null default 'manual', batch_id uuid, created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists item_price_history_lookup_idx on public.item_price_history(company_id,item_id,effective_from desc,created_at desc);

create table if not exists public.price_lists(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, currency text not null default 'EUR', client_id uuid references public.clients(id) on delete cascade,
  client_group text, valid_from date, valid_until date, priority integer not null default 0, is_active boolean not null default true,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,name)
);
create table if not exists public.price_list_items(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  price_list_id uuid not null references public.price_lists(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete cascade,
  variant_id uuid references public.item_variants(id) on delete cascade,
  fixed_price numeric(15,4), discount_rate numeric(7,4), coefficient numeric(12,6),
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists price_list_items_identity_idx on public.price_list_items(price_list_id,item_id,coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid));
create table if not exists public.price_tiers(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  price_list_item_id uuid not null references public.price_list_items(id) on delete cascade,
  min_quantity numeric(15,4) not null default 1, max_quantity numeric(15,4), fixed_price numeric(15,4), discount_rate numeric(7,4), coefficient numeric(12,6),
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(price_list_item_id,min_quantity)
);

create table if not exists public.item_bundle_components(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  bundle_item_id uuid not null references public.catalog_items(id) on delete cascade,
  component_item_id uuid not null references public.catalog_items(id) on delete restrict,
  component_variant_id uuid references public.item_variants(id) on delete restrict,
  quantity numeric(15,4) not null check(quantity>0), position integer not null default 0, client_visible boolean not null default true,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(bundle_item_id<>component_item_id)
);

create table if not exists public.item_notes(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete cascade,
  title text, content text not null, pinned boolean not null default false,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.item_activity_events(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid not null references public.catalog_items(id) on delete restrict,
  event_type text not null, source text not null default 'application', old_value jsonb, new_value jsonb, metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(), created_at timestamptz not null default now()
);
create index if not exists item_activity_events_lookup_idx on public.item_activity_events(company_id,item_id,created_at desc);

create table if not exists public.item_accounting_profiles(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  item_id uuid references public.catalog_items(id) on delete cascade, category_id uuid references public.catalog_categories(id) on delete cascade,
  item_type text, sales_account_code text, purchase_account_code text, vat_collected_code text, vat_deductible_code text,
  intracom_code text, export_code text, priority integer not null default 0, is_active boolean not null default true,
  created_by uuid default auth.uid(), updated_by uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.catalog_saved_views(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null default auth.uid(), name text not null, filters jsonb not null default '{}'::jsonb,
  columns jsonb not null default '[]'::jsonb, sort jsonb not null default '{}'::jsonb, is_default boolean not null default false,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,user_id,name)
);
create table if not exists public.item_import_jobs(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  file_name text not null, status text not null default 'pending', total_rows integer not null default 0,
  created_count integer not null default 0, updated_count integer not null default 0, skipped_count integer not null default 0, error_count integer not null default 0,
  mapping jsonb not null default '{}'::jsonb, report jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), completed_at timestamptz
);
create table if not exists public.item_import_rows(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  import_job_id uuid not null references public.item_import_jobs(id) on delete cascade, row_number integer not null,
  source_data jsonb not null, normalized_data jsonb, action text, status text not null default 'pending', errors jsonb not null default '[]'::jsonb,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), unique(import_job_id,row_number)
);

alter table public.document_lines add column if not exists variant_id uuid references public.item_variants(id) on delete restrict;
alter table public.document_lines add column if not exists category_snapshot text;
alter table public.document_lines add column if not exists accounting_code_snapshot text;
alter table public.document_lines add column if not exists price_history_id uuid references public.item_price_history(id) on delete restrict;
alter table public.document_lines add column if not exists price_list_id uuid references public.price_lists(id) on delete restrict;

create or replace function public.can_manage_catalog(target_company_id uuid,target_permission text default 'catalog_write')
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.company_members member
    where member.company_id=target_company_id and member.user_id=auth.uid()
      and (member.role in('owner','admin') or lower(coalesce(member.permissions->>target_permission,'false'))='true'
        or (member.role='sales' and target_permission in('catalog_read','catalog_create')))
  )
$$;
revoke all on function public.can_manage_catalog(uuid,text) from public,anon;
grant execute on function public.can_manage_catalog(uuid,text) to authenticated;

create or replace function public.next_catalog_reference(target_company_id uuid,target_item_type text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare settings public.company_catalog_settings%rowtype; next_value bigint; prefix text; result text;
begin
  if auth.uid() is null or not public.can_manage_catalog(target_company_id,'catalog_create') then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.company_catalog_settings(company_id,created_by) values(target_company_id,auth.uid()) on conflict(company_id) do nothing;
  select * into settings from public.company_catalog_settings where company_id=target_company_id for update;
  if target_item_type='service' then next_value:=settings.service_next_number;prefix:=settings.service_prefix;
    update public.company_catalog_settings set service_next_number=service_next_number+1,updated_by=auth.uid(),updated_at=now() where company_id=target_company_id;
  else next_value:=settings.product_next_number;prefix:=settings.product_prefix;
    update public.company_catalog_settings set product_next_number=product_next_number+1,updated_by=auth.uid(),updated_at=now() where company_id=target_company_id;
  end if;
  result:=replace(replace(settings.reference_format,'{PREFIX}',prefix),'{NUMBER}',lpad(next_value::text,settings.reference_padding,'0'));
  return result;
end $$;
revoke all on function public.next_catalog_reference(uuid,text) from public,anon;
grant execute on function public.next_catalog_reference(uuid,text) to authenticated;

create or replace function public.create_catalog_item(target_company_id uuid,target_item jsonb,target_suppliers jsonb default '[]'::jsonb,target_variants jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare new_id uuid; ref text; supplier jsonb; variant jsonb; kind text:=coalesce(target_item->>'item_type','product');
begin
  if auth.uid() is null or not public.can_manage_catalog(target_company_id,'catalog_create') then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(target_item->>'name'),'') is null then raise exception 'catalog_name_required' using errcode='22023'; end if;
  ref:=nullif(trim(target_item->>'reference'),'');
  if ref is null then ref:=public.next_catalog_reference(target_company_id,kind); end if;
  insert into public.catalog_items(company_id,item_type,reference,barcode,name,short_description,sales_description,detailed_description,internal_notes,category_id,subcategory,brand,unit,
    purchase_price,landing_cost,cost_price,sale_price,tax_rate,minimum_price,stock_managed,minimum_stock,maximum_stock,reorder_point,status,active,
    aliases,manufacturer_reference,country_of_origin,customs_code,weight,length,width,height,volume,billing_unit,estimated_duration_minutes,minimum_billable_minutes,billing_interval,recurring,created_by,updated_by)
  values(target_company_id,kind,ref,nullif(target_item->>'barcode',''),trim(target_item->>'name'),nullif(target_item->>'short_description',''),nullif(target_item->>'sales_description',''),nullif(target_item->>'detailed_description',''),nullif(target_item->>'internal_notes',''),
    nullif(target_item->>'category_id','')::uuid,nullif(target_item->>'subcategory',''),nullif(target_item->>'brand',''),coalesce(nullif(target_item->>'unit',''),'unité'),
    round(coalesce((target_item->>'purchase_price')::numeric,0),4),round(coalesce((target_item->>'landing_cost')::numeric,0),4),round(coalesce((target_item->>'cost_price')::numeric,(target_item->>'purchase_price')::numeric,0),4),round(coalesce((target_item->>'sale_price')::numeric,0),4),round(coalesce((target_item->>'tax_rate')::numeric,20),2),nullif(target_item->>'minimum_price','')::numeric,
    case when kind='service' then false else coalesce((target_item->>'stock_managed')::boolean,false) end,coalesce((target_item->>'minimum_stock')::numeric,0),nullif(target_item->>'maximum_stock','')::numeric,nullif(target_item->>'reorder_point','')::numeric,
    coalesce(nullif(target_item->>'status',''),'active'),coalesce((target_item->>'active')::boolean,true),coalesce(array(select jsonb_array_elements_text(coalesce(target_item->'aliases','[]'::jsonb))),'{}'),
    nullif(target_item->>'manufacturer_reference',''),nullif(target_item->>'country_of_origin',''),nullif(target_item->>'customs_code',''),nullif(target_item->>'weight','')::numeric,nullif(target_item->>'length','')::numeric,nullif(target_item->>'width','')::numeric,nullif(target_item->>'height','')::numeric,nullif(target_item->>'volume','')::numeric,
    nullif(target_item->>'billing_unit',''),nullif(target_item->>'estimated_duration_minutes','')::integer,nullif(target_item->>'minimum_billable_minutes','')::integer,nullif(target_item->>'billing_interval',''),coalesce((target_item->>'recurring')::boolean,false),auth.uid(),auth.uid()) returning id into new_id;
  for supplier in select value from jsonb_array_elements(coalesce(target_suppliers,'[]'::jsonb)) loop
    insert into public.supplier_items(company_id,supplier_id,catalog_item_id,supplier_reference,supplier_designation,purchase_price,lead_days,minimum_order_quantity,package_quantity,currency,discount_rate,approach_fees,is_primary,active,created_by)
    values(target_company_id,(supplier->>'supplier_id')::uuid,new_id,nullif(supplier->>'supplier_reference',''),nullif(supplier->>'supplier_designation',''),nullif(supplier->>'purchase_price','')::numeric,nullif(supplier->>'lead_days','')::integer,nullif(supplier->>'minimum_order_quantity','')::numeric,nullif(supplier->>'package_quantity','')::numeric,coalesce(nullif(supplier->>'currency',''),'EUR'),coalesce((supplier->>'discount_rate')::numeric,0),coalesce((supplier->>'approach_fees')::numeric,0),coalesce((supplier->>'is_primary')::boolean,false),true,auth.uid());
  end loop;
  for variant in select value from jsonb_array_elements(coalesce(target_variants,'[]'::jsonb)) loop
    insert into public.item_variants(company_id,item_id,name,reference,barcode,attribute_values,purchase_price,cost_price,sale_price,tax_rate,created_by,updated_by)
    values(target_company_id,new_id,coalesce(nullif(variant->>'name',''),trim(target_item->>'name')),coalesce(nullif(variant->>'reference',''),ref||'-'||substr(gen_random_uuid()::text,1,6)),nullif(variant->>'barcode',''),coalesce(variant->'attribute_values','{}'::jsonb),nullif(variant->>'purchase_price','')::numeric,nullif(variant->>'cost_price','')::numeric,nullif(variant->>'sale_price','')::numeric,nullif(variant->>'tax_rate','')::numeric,auth.uid(),auth.uid());
  end loop;
  insert into public.item_price_history(company_id,item_id,new_purchase_price,new_landing_cost,new_cost_price,new_sale_price,new_margin,effective_from,reason,source,created_by)
  select target_company_id,id,purchase_price,landing_cost,cost_price,sale_price,sale_price-cost_price,current_date,'Création','manual',auth.uid() from public.catalog_items where id=new_id;
  insert into public.item_activity_events(company_id,item_id,event_type,new_value,created_by) values(target_company_id,new_id,'item.created',jsonb_build_object('reference',ref,'name',target_item->>'name'),auth.uid());
  return new_id;
exception when unique_violation then raise exception 'catalog_reference_or_barcode_already_exists' using errcode='23505';
end $$;
revoke all on function public.create_catalog_item(uuid,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.create_catalog_item(uuid,jsonb,jsonb,jsonb) to authenticated;

create or replace function public.create_catalog_variants(target_item_id uuid,target_attributes jsonb default '[]'::jsonb,target_variants jsonb default '[]'::jsonb)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare item public.catalog_items%rowtype; attribute jsonb; variant jsonb; created_count integer:=0;
begin
  select * into item from public.catalog_items where id=target_item_id for update;
  if auth.uid() is null or item.id is null or not public.can_manage_catalog(item.company_id,'catalog_write') then raise exception 'forbidden' using errcode='42501'; end if;
  if item.item_type='service' then raise exception 'service_variants_forbidden' using errcode='22023'; end if;
  if jsonb_array_length(coalesce(target_variants,'[]'::jsonb))>100 then raise exception 'too_many_variants' using errcode='22023'; end if;
  for attribute in select value from jsonb_array_elements(coalesce(target_attributes,'[]'::jsonb)) loop
    if nullif(trim(attribute->>'name'),'') is null then raise exception 'variant_attribute_name_required' using errcode='22023'; end if;
    insert into public.item_variant_attributes(company_id,item_id,name,values,position,created_by,updated_by)
    values(item.company_id,item.id,trim(attribute->>'name'),coalesce(array(select jsonb_array_elements_text(coalesce(attribute->'values','[]'::jsonb))),'{}'),coalesce((attribute->>'position')::integer,0),auth.uid(),auth.uid())
    on conflict(item_id,name) do update set values=excluded.values,position=excluded.position,updated_by=auth.uid(),updated_at=now();
  end loop;
  for variant in select value from jsonb_array_elements(coalesce(target_variants,'[]'::jsonb)) loop
    if nullif(trim(variant->>'name'),'') is null or nullif(trim(variant->>'reference'),'') is null then raise exception 'variant_name_and_reference_required' using errcode='22023'; end if;
    insert into public.item_variants(company_id,item_id,name,reference,barcode,attribute_values,purchase_price,cost_price,sale_price,tax_rate,weight,minimum_stock,status,is_active,created_by,updated_by)
    values(item.company_id,item.id,trim(variant->>'name'),trim(variant->>'reference'),nullif(variant->>'barcode',''),coalesce(variant->'attribute_values','{}'::jsonb),nullif(variant->>'purchase_price','')::numeric,nullif(variant->>'cost_price','')::numeric,nullif(variant->>'sale_price','')::numeric,nullif(variant->>'tax_rate','')::numeric,nullif(variant->>'weight','')::numeric,coalesce((variant->>'minimum_stock')::numeric,0),'active',true,auth.uid(),auth.uid());
    created_count:=created_count+1;
  end loop;
  insert into public.item_activity_events(company_id,item_id,event_type,new_value,created_by)
  values(item.company_id,item.id,'variants.created',jsonb_build_object('count',created_count,'attributes',target_attributes),auth.uid());
  return created_count;
exception when unique_violation then raise exception 'variant_reference_barcode_or_combination_already_exists' using errcode='23505';
end $$;
revoke all on function public.create_catalog_variants(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.create_catalog_variants(uuid,jsonb,jsonb) to authenticated;

create or replace function public.change_catalog_price(target_item_id uuid,target_purchase_price numeric,target_landing_cost numeric,target_sale_price numeric,target_effective_from date default current_date,target_reason text default null,target_source text default 'manual')
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare item public.catalog_items%rowtype; history_id uuid; next_cost numeric;
begin
  select * into item from public.catalog_items where id=target_item_id for update;
  if item.id is null or not public.can_manage_catalog(item.company_id,'catalog_price_write') then raise exception 'forbidden' using errcode='42501'; end if;
  next_cost:=round(coalesce(target_purchase_price,item.purchase_price)+coalesce(target_landing_cost,item.landing_cost),4);
  insert into public.item_price_history(company_id,item_id,old_purchase_price,new_purchase_price,old_landing_cost,new_landing_cost,old_cost_price,new_cost_price,old_sale_price,new_sale_price,old_margin,new_margin,effective_from,reason,source,created_by)
  values(item.company_id,item.id,item.purchase_price,coalesce(target_purchase_price,item.purchase_price),item.landing_cost,coalesce(target_landing_cost,item.landing_cost),item.cost_price,next_cost,item.sale_price,coalesce(target_sale_price,item.sale_price),item.sale_price-item.cost_price,coalesce(target_sale_price,item.sale_price)-next_cost,coalesce(target_effective_from,current_date),target_reason,coalesce(target_source,'manual'),auth.uid()) returning id into history_id;
  if coalesce(target_effective_from,current_date)<=current_date then
    update public.catalog_items set purchase_price=round(coalesce(target_purchase_price,purchase_price),4),landing_cost=round(coalesce(target_landing_cost,landing_cost),4),cost_price=next_cost,sale_price=round(coalesce(target_sale_price,sale_price),4),updated_by=auth.uid() where id=item.id;
  end if;
  return history_id;
end $$;
revoke all on function public.change_catalog_price(uuid,numeric,numeric,numeric,date,text,text) from public,anon;
grant execute on function public.change_catalog_price(uuid,numeric,numeric,numeric,date,text,text) to authenticated;

create or replace function public.resolve_catalog_price(target_item_id uuid,target_client_id uuid default null,target_quantity numeric default 1,target_date date default current_date,target_variant_id uuid default null)
returns table(unit_price numeric,source text,price_list_id uuid,price_history_id uuid) language sql stable security definer set search_path=public,pg_temp as $$
  with item as (select i.* from public.catalog_items i where i.id=target_item_id and public.is_company_member(i.company_id)),
  list_price as (
    select coalesce(t.fixed_price,pli.fixed_price,round(i.sale_price*(1-coalesce(t.discount_rate,pli.discount_rate,0)/100)*coalesce(t.coefficient,pli.coefficient,1),4)) value,
      pl.id list_id
    from item i join public.price_list_items pli on pli.item_id=i.id and (pli.variant_id is null or pli.variant_id=target_variant_id)
    join public.price_lists pl on pl.id=pli.price_list_id and pl.is_active and (pl.client_id is null or pl.client_id=target_client_id)
      and (pl.valid_from is null or pl.valid_from<=target_date) and (pl.valid_until is null or pl.valid_until>=target_date)
    left join public.price_tiers t on t.price_list_item_id=pli.id and t.min_quantity<=target_quantity and (t.max_quantity is null or t.max_quantity>=target_quantity)
    order by (pl.client_id is not null) desc,pl.priority desc,t.min_quantity desc limit 1
  ), scheduled as (
    select h.new_sale_price value,h.id history_id from item i join public.item_price_history h on h.item_id=i.id
    where h.effective_from<=target_date and h.new_sale_price is not null order by h.effective_from desc,h.created_at desc limit 1
  )
  select coalesce(lp.value,v.sale_price,s.value,i.sale_price),case when lp.value is not null then 'Grille tarifaire' when v.sale_price is not null then 'Variante' when s.value is not null then 'Historique de prix' else 'Tarif standard' end,lp.list_id,s.history_id
  from item i left join list_price lp on true left join scheduled s on true left join public.item_variants v on v.id=target_variant_id and v.item_id=i.id
$$;
revoke all on function public.resolve_catalog_price(uuid,uuid,numeric,date,uuid) from public,anon;
grant execute on function public.resolve_catalog_price(uuid,uuid,numeric,date,uuid) to authenticated;

create or replace function public.duplicate_catalog_item(target_item_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare item public.catalog_items%rowtype; new_id uuid; new_ref text;
begin
  select * into item from public.catalog_items where id=target_item_id;
  if item.id is null or not public.can_manage_catalog(item.company_id,'catalog_create') then raise exception 'forbidden' using errcode='42501'; end if;
  new_ref:=public.next_catalog_reference(item.company_id,item.item_type);
  insert into public.catalog_items(company_id,item_type,reference,barcode,name,short_description,sales_description,detailed_description,internal_notes,category,category_id,subcategory,brand,unit,image_path,purchase_price,landing_cost,cost_price,sale_price,tax_rate,minimum_price,stock_managed,minimum_stock,maximum_stock,reorder_point,valuation_method,status,active,aliases,manufacturer_reference,country_of_origin,customs_code,weight,length,width,height,volume,billing_unit,estimated_duration_minutes,minimum_billable_minutes,billing_interval,recurring,created_by,updated_by)
  select company_id,item_type,new_ref,null,name||' (copie)',short_description,sales_description,detailed_description,internal_notes,category,category_id,subcategory,brand,unit,image_path,purchase_price,landing_cost,cost_price,sale_price,tax_rate,minimum_price,stock_managed,minimum_stock,maximum_stock,reorder_point,valuation_method,'draft',false,aliases,manufacturer_reference,country_of_origin,customs_code,weight,length,width,height,volume,billing_unit,estimated_duration_minutes,minimum_billable_minutes,billing_interval,recurring,auth.uid(),auth.uid() from public.catalog_items where id=item.id returning id into new_id;
  insert into public.supplier_items(company_id,supplier_id,catalog_item_id,supplier_reference,supplier_designation,purchase_price,lead_days,minimum_order_quantity,package_quantity,currency,discount_rate,approach_fees,is_primary,active,created_by)
  select company_id,supplier_id,new_id,supplier_reference,supplier_designation,purchase_price,lead_days,minimum_order_quantity,package_quantity,currency,discount_rate,approach_fees,is_primary,active,auth.uid() from public.supplier_items where catalog_item_id=item.id;
  insert into public.item_activity_events(company_id,item_id,event_type,metadata,created_by) values(item.company_id,new_id,'item.duplicated',jsonb_build_object('source_item_id',item.id),auth.uid());
  return new_id;
end $$;
revoke all on function public.duplicate_catalog_item(uuid) from public,anon;
grant execute on function public.duplicate_catalog_item(uuid) to authenticated;

create or replace function public.archive_or_delete_catalog_item(target_item_id uuid,target_delete boolean default false)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare item public.catalog_items%rowtype; used boolean;
begin
  select * into item from public.catalog_items where id=target_item_id for update;
  if item.id is null or not public.can_manage_catalog(item.company_id,case when target_delete then 'catalog_delete' else 'catalog_archive' end) then raise exception 'forbidden' using errcode='42501'; end if;
  select exists(select 1 from public.document_lines where item_id=item.id union all select 1 from public.stock_movements where item_id=item.id union all select 1 from public.supplier_items where catalog_item_id=item.id union all select 1 from public.item_variants where item_id=item.id) into used;
  if target_delete and not used then delete from public.catalog_items where id=item.id;return 'deleted'; end if;
  update public.catalog_items set status='archived',active=false,archived_at=now(),updated_by=auth.uid() where id=item.id;
  insert into public.item_activity_events(company_id,item_id,event_type,created_by) values(item.company_id,item.id,'item.archived',auth.uid());
  return case when target_delete then 'archived_used_item' else 'archived' end;
end $$;
revoke all on function public.archive_or_delete_catalog_item(uuid,boolean) from public,anon;
grant execute on function public.archive_or_delete_catalog_item(uuid,boolean) to authenticated;

-- Empêche également une suppression SQL directe de contourner la règle métier.
create or replace function public.prevent_used_catalog_item_delete()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if exists(select 1 from public.document_lines where item_id=old.id)
    or exists(select 1 from public.stock_movements where item_id=old.id)
    or exists(select 1 from public.supplier_items where catalog_item_id=old.id)
    or exists(select 1 from public.item_variants where item_id=old.id)
  then
    raise exception 'catalog_item_is_used_archive_required' using errcode='23503';
  end if;
  return old;
end $$;
drop trigger if exists catalog_items_prevent_used_delete on public.catalog_items;
create trigger catalog_items_prevent_used_delete before delete on public.catalog_items
for each row execute function public.prevent_used_catalog_item_delete();

-- Remplace la version historique par une version qui ne fait confiance ni au
-- company_id, ni aux entrepôts transmis par le navigateur.
create or replace function public.post_stock_movement(
  target_company_id uuid,target_item_id uuid,target_movement_type text,target_quantity numeric,target_unit text,
  source_warehouse_id uuid default null,destination_warehouse_id uuid default null,
  source_location_id uuid default null,destination_location_id uuid default null,
  movement_reason text default null,movement_comment text default null,target_unit_cost numeric default 0
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare movement_id uuid; item_company uuid;
begin
  if auth.uid() is null or not public.can_manage_catalog(target_company_id,'adjust_stock') then raise exception 'forbidden' using errcode='42501'; end if;
  select company_id into item_company from public.catalog_items where id=target_item_id and stock_managed;
  if item_company is distinct from target_company_id then raise exception 'catalog_item_company_mismatch' using errcode='23514'; end if;
  if target_quantity is null or target_quantity<=0 then raise exception 'invalid_quantity' using errcode='22023'; end if;
  if target_movement_type not in('supplier_receipt','customer_delivery','customer_return','supplier_return','transfer','positive_adjustment','negative_adjustment','inventory','damage','loss','opening') then raise exception 'invalid_movement_type' using errcode='22023'; end if;
  if source_warehouse_id is not null and not exists(select 1 from public.warehouses where id=source_warehouse_id and company_id=target_company_id) then raise exception 'source_warehouse_company_mismatch' using errcode='23514'; end if;
  if destination_warehouse_id is not null and not exists(select 1 from public.warehouses where id=destination_warehouse_id and company_id=target_company_id) then raise exception 'destination_warehouse_company_mismatch' using errcode='23514'; end if;
  if source_location_id is not null and not exists(select 1 from public.warehouse_locations where id=source_location_id and warehouse_id=source_warehouse_id and company_id=target_company_id) then raise exception 'source_location_company_mismatch' using errcode='23514'; end if;
  if destination_location_id is not null and not exists(select 1 from public.warehouse_locations where id=destination_location_id and warehouse_id=destination_warehouse_id and company_id=target_company_id) then raise exception 'destination_location_company_mismatch' using errcode='23514'; end if;
  if target_movement_type='transfer' and (source_warehouse_id is null or destination_warehouse_id is null or source_warehouse_id=destination_warehouse_id and source_location_id is not distinct from destination_location_id) then raise exception 'invalid_transfer' using errcode='22023'; end if;
  insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,to_warehouse_id,to_location_id,reason,comment,unit_cost,status,created_by)
  values(target_company_id,target_item_id,target_movement_type,target_quantity,coalesce(nullif(target_unit,''),'unité'),source_warehouse_id,source_location_id,destination_warehouse_id,destination_location_id,movement_reason,movement_comment,coalesce(target_unit_cost,0),'validated',auth.uid()) returning id into movement_id;
  insert into public.item_activity_events(company_id,item_id,event_type,metadata,created_by)
  values(target_company_id,target_item_id,'stock.movement',jsonb_build_object('movement_id',movement_id,'type',target_movement_type,'quantity',target_quantity),auth.uid());
  return movement_id;
end $$;
revoke all on function public.post_stock_movement(uuid,uuid,text,numeric,text,uuid,uuid,uuid,uuid,text,text,numeric) from public,anon;
grant execute on function public.post_stock_movement(uuid,uuid,text,numeric,text,uuid,uuid,uuid,uuid,text,text,numeric) to authenticated;

create or replace function public.transfer_catalog_stock(target_item_id uuid,target_quantity numeric,target_unit text,target_from_warehouse_id uuid,target_to_warehouse_id uuid,target_from_location_id uuid default null,target_to_location_id uuid default null,target_variant_id uuid default null,target_reason text default 'Transfert interne')
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare item_company uuid; movement_id uuid; group_id uuid:=gen_random_uuid();
begin
  select company_id into item_company from public.catalog_items where id=target_item_id;
  movement_id:=public.post_stock_movement(item_company,target_item_id,'transfer',target_quantity,target_unit,target_from_warehouse_id,target_to_warehouse_id,target_from_location_id,target_to_location_id,target_reason,null,0);
  if target_variant_id is not null and not exists(select 1 from public.item_variants where id=target_variant_id and item_id=target_item_id and company_id=item_company) then raise exception 'catalog_variant_company_mismatch' using errcode='23514'; end if;
  update public.stock_movements set variant_id=target_variant_id,transfer_group_id=group_id where id=movement_id;
  return movement_id;
end $$;
revoke all on function public.transfer_catalog_stock(uuid,numeric,text,uuid,uuid,uuid,uuid,uuid,text) from public,anon;
grant execute on function public.transfer_catalog_stock(uuid,numeric,text,uuid,uuid,uuid,uuid,uuid,text) to authenticated;

create or replace function public.reserve_catalog_stock(target_item_id uuid,target_warehouse_id uuid,target_quantity numeric,target_source_type text,target_source_id uuid,target_location_id uuid default null,target_variant_id uuid default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare item_company uuid; available numeric; reservation_id uuid;
begin
  select company_id into item_company from public.catalog_items where id=target_item_id and stock_managed;
  if auth.uid() is null or item_company is null or not public.can_manage_catalog(item_company,'manage_stock') then raise exception 'forbidden' using errcode='42501'; end if;
  if target_quantity is null or target_quantity<=0 then raise exception 'invalid_quantity' using errcode='22023'; end if;
  if not exists(select 1 from public.warehouses where id=target_warehouse_id and company_id=item_company) then raise exception 'warehouse_company_mismatch' using errcode='23514'; end if;
  if target_location_id is not null and not exists(select 1 from public.warehouse_locations where id=target_location_id and warehouse_id=target_warehouse_id and company_id=item_company) then raise exception 'location_company_mismatch' using errcode='23514'; end if;
  if target_variant_id is not null and not exists(select 1 from public.item_variants where id=target_variant_id and item_id=target_item_id and company_id=item_company) then raise exception 'catalog_variant_company_mismatch' using errcode='23514'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_item_id::text||':'||target_warehouse_id::text||':'||coalesce(target_location_id::text,'*'),0));
  select coalesce(sum(physical_quantity-reserved_quantity),0) into available from public.stock_levels
  where company_id=item_company and item_id=target_item_id and warehouse_id=target_warehouse_id and (target_location_id is null or location_id=target_location_id);
  if available<target_quantity then raise exception 'insufficient_available_stock:%',available using errcode='23514'; end if;
  insert into public.stock_reservations(company_id,item_id,variant_id,warehouse_id,location_id,quantity,source_type,source_id,status,created_by)
  values(item_company,target_item_id,target_variant_id,target_warehouse_id,target_location_id,target_quantity,target_source_type,target_source_id,'active',auth.uid()) returning id into reservation_id;
  insert into public.item_activity_events(company_id,item_id,event_type,metadata,created_by)
  values(item_company,target_item_id,'stock.reserved',jsonb_build_object('reservation_id',reservation_id,'quantity',target_quantity,'source_type',target_source_type,'source_id',target_source_id),auth.uid());
  return reservation_id;
end $$;
revoke all on function public.reserve_catalog_stock(uuid,uuid,numeric,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.reserve_catalog_stock(uuid,uuid,numeric,text,uuid,uuid,uuid) to authenticated;

create or replace function public.release_catalog_reservation(target_reservation_id uuid,target_reason text default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare reservation public.stock_reservations%rowtype;
begin
  select * into reservation from public.stock_reservations where id=target_reservation_id for update;
  if auth.uid() is null or reservation.id is null or not public.can_manage_catalog(reservation.company_id,'manage_stock') then raise exception 'forbidden' using errcode='42501'; end if;
  if reservation.status<>'active' then raise exception 'reservation_not_active' using errcode='23514'; end if;
  update public.stock_reservations set status='released',updated_at=now() where id=reservation.id;
  insert into public.item_activity_events(company_id,item_id,event_type,metadata,created_by)
  values(reservation.company_id,reservation.item_id,'stock.released',jsonb_build_object('reservation_id',reservation.id,'quantity',reservation.quantity,'reason',target_reason),auth.uid());
  return reservation.id;
end $$;
revoke all on function public.release_catalog_reservation(uuid,text) from public,anon;
grant execute on function public.release_catalog_reservation(uuid,text) to authenticated;

create or replace function public.change_catalog_prices_bulk(target_item_ids uuid[],target_mode text,target_operation text,target_value numeric,target_reason text default null)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare target_id uuid; item public.catalog_items%rowtype; next_purchase numeric; next_sale numeric; changed integer:=0; multiplier numeric;
begin
  if coalesce(array_length(target_item_ids,1),0)=0 or target_value is null then return 0; end if;
  foreach target_id in array target_item_ids loop
    select * into item from public.catalog_items where id=target_id;
    if item.id is null or not public.can_manage_catalog(item.company_id,'catalog_price_write') then raise exception 'forbidden' using errcode='42501'; end if;
    multiplier:=case when target_operation='increase_percent' then 1+target_value/100 when target_operation='decrease_percent' then 1-target_value/100 when target_operation='coefficient' then target_value else 1 end;
    next_purchase:=case when target_mode='purchase' then case when target_operation='add_amount' then item.purchase_price+target_value else item.purchase_price*multiplier end else item.purchase_price end;
    next_sale:=case when target_mode='sale' then case when target_operation='add_amount' then item.sale_price+target_value else item.sale_price*multiplier end else item.sale_price end;
    perform public.change_catalog_price(item.id,greatest(next_purchase,0),item.landing_cost,greatest(next_sale,0),current_date,coalesce(target_reason,'Modification en masse'),'bulk');
    changed:=changed+1;
  end loop;
  return changed;
end $$;
revoke all on function public.change_catalog_prices_bulk(uuid[],text,text,numeric,text) from public,anon;
grant execute on function public.change_catalog_prices_bulk(uuid[],text,text,numeric,text) to authenticated;

create or replace function public.prepare_document_line_catalog_snapshot()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare item public.catalog_items%rowtype; profile_code text;
begin
  if new.item_id is null then return new; end if;
  select * into item from public.catalog_items where id=new.item_id and company_id=new.company_id;
  if item.id is null then raise exception 'catalog_item_company_mismatch' using errcode='23514'; end if;
  select coalesce(p.sales_account_code,p.purchase_account_code) into profile_code from public.item_accounting_profiles p
    where p.company_id=new.company_id and p.is_active and (p.item_id=item.id or p.category_id=item.category_id or p.item_type=item.item_type or (p.item_id is null and p.category_id is null and p.item_type is null))
    order by (p.item_id is not null) desc,(p.category_id is not null) desc,(p.item_type is not null) desc,p.priority desc limit 1;
  new.variant_id:=coalesce(new.variant_id,nullif(new.line_metadata->>'variant_id','')::uuid);
  new.category_snapshot:=coalesce(new.category_snapshot,item.category,(select name from public.catalog_categories where id=item.category_id));
  new.accounting_code_snapshot:=coalesce(new.accounting_code_snapshot,profile_code);
  new.price_history_id:=coalesce(new.price_history_id,nullif(new.line_metadata->>'price_history_id','')::uuid);
  new.price_list_id:=coalesce(new.price_list_id,nullif(new.line_metadata->>'price_list_id','')::uuid);
  new.line_metadata:=coalesce(new.line_metadata,'{}'::jsonb)||jsonb_build_object('catalog_snapshot',jsonb_build_object('item_id',item.id,'variant_id',new.variant_id,'reference',new.reference,'name',new.name,'description',new.description,'unit',new.unit,'unit_cost',new.unit_cost_snapshot,'unit_price',new.unit_price,'tax_rate',new.tax_rate,'category',new.category_snapshot,'accounting_code',new.accounting_code_snapshot,'price_history_id',new.price_history_id,'price_list_id',new.price_list_id));
  return new;
end $$;
drop trigger if exists document_lines_catalog_snapshot on public.document_lines;
create trigger document_lines_catalog_snapshot before insert or update of item_id,variant_id,reference,name,description,unit,unit_cost_snapshot,unit_price,tax_rate,line_metadata on public.document_lines for each row execute function public.prepare_document_line_catalog_snapshot();

create index if not exists catalog_items_company_status_name_idx on public.catalog_items(company_id,status,lower(name));
create index if not exists catalog_items_company_barcode_idx on public.catalog_items(company_id,barcode) where barcode is not null;
create index if not exists catalog_items_category_idx on public.catalog_items(company_id,category_id);
create index if not exists catalog_items_updated_idx on public.catalog_items(company_id,updated_at desc);
create index if not exists supplier_items_catalog_idx on public.supplier_items(company_id,catalog_item_id,active);
create index if not exists item_variants_search_idx on public.item_variants(company_id,item_id,lower(name),reference);
create index if not exists document_lines_item_idx on public.document_lines(company_id,item_id,document_id);
create index if not exists stock_reservations_catalog_idx on public.stock_reservations(company_id,item_id,warehouse_id,status);
create index if not exists stock_movements_variant_idx on public.stock_movements(company_id,item_id,variant_id,occurred_at desc);

do $rls$
declare table_name text;
begin
  foreach table_name in array array['company_catalog_settings','item_tags','item_tag_assignments','item_variant_attributes','item_variants','item_price_history','price_lists','price_list_items','price_tiers','item_bundle_components','item_notes','item_activity_events','item_accounting_profiles','catalog_saved_views','item_import_jobs','item_import_rows'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.can_manage_catalog(company_id,''catalog_write'') and created_by=auth.uid())',table_name||'_insert',table_name);
    if table_name not in ('item_price_history','item_activity_events') then
      execute format('create policy %I on public.%I for update to authenticated using(public.can_manage_catalog(company_id,''catalog_write'')) with check(public.can_manage_catalog(company_id,''catalog_write''))',table_name||'_update',table_name);
    end if;
    if table_name not in ('item_price_history','item_activity_events') then
      execute format('create policy %I on public.%I for delete to authenticated using(public.can_manage_catalog(company_id,''catalog_delete''))',table_name||'_delete',table_name);
    end if;
  end loop;
end $rls$;

do $triggers$
declare table_name text;
begin
  foreach table_name in array array['company_catalog_settings','item_tags','item_variant_attributes','item_variants','price_lists','price_list_items','price_tiers','item_bundle_components','item_notes','item_accounting_profiles','catalog_saved_views'] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_set_updated_at',table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
  end loop;
end $triggers$;

grant select on public.company_catalog_settings,public.item_tags,public.item_tag_assignments,public.item_variant_attributes,public.price_lists,public.price_list_items,public.price_tiers,public.item_bundle_components,public.item_notes,public.item_activity_events,public.item_accounting_profiles,public.catalog_saved_views,public.item_import_jobs,public.item_import_rows to authenticated;
grant insert,update,delete on public.company_catalog_settings,public.item_tags,public.item_tag_assignments,public.item_variant_attributes,public.item_variants,public.price_lists,public.price_list_items,public.price_tiers,public.item_bundle_components,public.item_notes,public.item_accounting_profiles,public.catalog_saved_views,public.item_import_jobs,public.item_import_rows to authenticated;
grant select on public.item_activity_events to authenticated;

-- Les coûts fournisseurs, coûts de variantes et marges historiques restent
-- inaccessibles par requête REST directe. Ils sont restitués uniquement par la
-- fonction financière existante, selon les permissions du membre.
revoke select on table public.supplier_items,public.item_variants,public.item_price_history from anon,authenticated;
grant select(id,company_id,supplier_id,catalog_item_id,supplier_reference,supplier_designation,lead_days,minimum_order_quantity,package_quantity,currency,price_updated_at,valid_from,valid_until,is_primary,active,created_by,created_at,updated_at) on public.supplier_items to authenticated;
grant select(id,company_id,item_id,name,reference,barcode,attribute_values,sale_price,tax_rate,weight,image_path,minimum_stock,supplier_id,status,is_active,created_by,updated_by,created_at,updated_at) on public.item_variants to authenticated;
grant select(id,company_id,item_id,variant_id,old_sale_price,new_sale_price,effective_from,reason,source,batch_id,created_by,created_at) on public.item_price_history to authenticated;

create or replace function public.get_company_financial_fields(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare can_purchase boolean;can_margin boolean;
begin
 if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
 can_purchase:=public.has_company_permission(target_company_id,'view_purchase_prices');
 can_margin:=public.has_company_permission(target_company_id,'view_margins');
 return jsonb_build_object(
  'catalog',case when can_purchase or can_margin then coalesce((select jsonb_agg(jsonb_build_object('id',id,'purchase_price',purchase_price,'landing_cost',landing_cost,'cost_price',cost_price)) from public.catalog_items where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'documents',case when can_margin then coalesce((select jsonb_agg(jsonb_build_object('id',id,'total_cost',total_cost)) from public.documents where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'lines',case when can_purchase or can_margin then coalesce((select jsonb_agg(jsonb_build_object('id',id,'unit_cost_snapshot',unit_cost_snapshot)) from public.document_lines where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'movements',case when can_purchase then coalesce((select jsonb_agg(jsonb_build_object('id',id,'unit_cost',unit_cost,'total_value',total_value)) from public.stock_movements where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'supplier_items',case when can_purchase then coalesce((select jsonb_agg(jsonb_build_object('id',id,'purchase_price',purchase_price,'discount_rate',discount_rate,'approach_fees',approach_fees)) from public.supplier_items where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'item_variants',case when can_purchase or can_margin then coalesce((select jsonb_agg(jsonb_build_object('id',id,'purchase_price',purchase_price,'cost_price',cost_price)) from public.item_variants where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end,
  'item_price_history',case when can_purchase or can_margin then coalesce((select jsonb_agg(jsonb_build_object('id',id,'old_purchase_price',old_purchase_price,'new_purchase_price',new_purchase_price,'old_landing_cost',old_landing_cost,'new_landing_cost',new_landing_cost,'old_cost_price',old_cost_price,'new_cost_price',new_cost_price,'old_margin',case when can_margin then old_margin else null end,'new_margin',case when can_margin then new_margin else null end)) from public.item_price_history where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end
 );
end $$;
revoke all on function public.get_company_financial_fields(uuid) from public,anon;
grant execute on function public.get_company_financial_fields(uuid) to authenticated;

drop policy if exists supplier_items_insert on public.supplier_items;
drop policy if exists supplier_items_update on public.supplier_items;
drop policy if exists supplier_items_delete on public.supplier_items;
create policy supplier_items_insert_catalog on public.supplier_items for insert to authenticated
 with check(public.can_manage_catalog(company_id,'catalog_write') and created_by=auth.uid());
create policy supplier_items_update_catalog on public.supplier_items for update to authenticated
 using(public.can_manage_catalog(company_id,'catalog_write')) with check(public.can_manage_catalog(company_id,'catalog_write'));
create policy supplier_items_delete_catalog on public.supplier_items for delete to authenticated
 using(public.can_manage_catalog(company_id,'catalog_delete'));

drop policy if exists catalog_items_insert on public.catalog_items;
drop policy if exists catalog_items_update on public.catalog_items;
drop policy if exists catalog_items_delete on public.catalog_items;
create policy catalog_items_insert_catalog on public.catalog_items for insert to authenticated
 with check(public.can_manage_catalog(company_id,'catalog_create') and created_by=auth.uid());
create policy catalog_items_update_catalog on public.catalog_items for update to authenticated
 using(public.can_manage_catalog(company_id,'catalog_write')) with check(public.can_manage_catalog(company_id,'catalog_write'));
create policy catalog_items_delete_catalog on public.catalog_items for delete to authenticated
 using(public.can_manage_catalog(company_id,'catalog_delete'));

drop policy if exists catalog_categories_insert on public.catalog_categories;
drop policy if exists catalog_categories_update on public.catalog_categories;
drop policy if exists catalog_categories_delete on public.catalog_categories;
create policy catalog_categories_insert_catalog on public.catalog_categories for insert to authenticated
 with check(public.can_manage_catalog(company_id,'catalog_write') and created_by=auth.uid());
create policy catalog_categories_update_catalog on public.catalog_categories for update to authenticated
 using(public.can_manage_catalog(company_id,'catalog_write')) with check(public.can_manage_catalog(company_id,'catalog_write'));
create policy catalog_categories_delete_catalog on public.catalog_categories for delete to authenticated
 using(public.can_manage_catalog(company_id,'catalog_delete'));

drop policy if exists stock_movements_insert on public.stock_movements;
drop policy if exists stock_movements_update on public.stock_movements;
drop policy if exists stock_movements_delete_draft on public.stock_movements;
drop policy if exists stock_movements_insert_authorized on public.stock_movements;
drop policy if exists stock_movements_update_draft_authorized on public.stock_movements;
create policy stock_movements_insert_authorized on public.stock_movements for insert to authenticated
 with check(public.has_company_permission(company_id,'adjust_stock') and created_by=auth.uid());
create policy stock_movements_update_authorized on public.stock_movements for update to authenticated
 using(public.has_company_permission(company_id,'adjust_stock')) with check(public.has_company_permission(company_id,'adjust_stock'));
create policy stock_movements_delete_draft_authorized on public.stock_movements for delete to authenticated
 using(status='draft' and public.has_company_permission(company_id,'adjust_stock'));

drop policy if exists stock_reservations_insert on public.stock_reservations;
drop policy if exists stock_reservations_update on public.stock_reservations;
drop policy if exists stock_reservations_delete on public.stock_reservations;
create policy stock_reservations_insert_authorized on public.stock_reservations for insert to authenticated
 with check(public.has_company_permission(company_id,'adjust_stock') and created_by=auth.uid());
create policy stock_reservations_update_authorized on public.stock_reservations for update to authenticated
 using(public.has_company_permission(company_id,'adjust_stock')) with check(public.has_company_permission(company_id,'adjust_stock'));
create policy stock_reservations_delete_authorized on public.stock_reservations for delete to authenticated
 using(public.has_company_permission(company_id,'adjust_stock'));

create or replace function public.protect_supplier_item_costs()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_company_permission(new.company_id,'view_purchase_prices') then
  if tg_op='UPDATE' then
   new.purchase_price:=old.purchase_price;new.discount_rate:=old.discount_rate;new.approach_fees:=old.approach_fees;
  else
   new.purchase_price:=null;new.discount_rate:=0;new.approach_fees:=0;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists supplier_items_protect_costs on public.supplier_items;
create trigger supplier_items_protect_costs before insert or update on public.supplier_items
 for each row execute function public.protect_supplier_item_costs();

create or replace function public.protect_item_variant_costs()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_company_permission(new.company_id,'view_purchase_prices') then
  if tg_op='UPDATE' then new.purchase_price:=old.purchase_price;new.cost_price:=old.cost_price;
  else new.purchase_price:=null;new.cost_price:=null;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists item_variants_protect_costs on public.item_variants;
create trigger item_variants_protect_costs before insert or update on public.item_variants
 for each row execute function public.protect_item_variant_costs();

drop policy if exists item_import_jobs_select on public.item_import_jobs;
drop policy if exists item_import_rows_select on public.item_import_rows;
create policy item_import_jobs_select on public.item_import_jobs for select to authenticated
 using(public.can_manage_catalog(company_id,'catalog_write'));
create policy item_import_rows_select on public.item_import_rows for select to authenticated
 using(public.can_manage_catalog(company_id,'catalog_write'));

-- Les tables historiques utilisaient déjà des privilèges par colonne pour les
-- données sensibles. Les nouveaux champs fonctionnels sont explicitement lus.
grant select(status,detailed_description,internal_notes,aliases,manufacturer_reference,country_of_origin,customs_code,weight,length,width,height,volume,available_from,discontinued_at,track_lots,track_serials,billing_unit,estimated_duration_minutes,minimum_billable_minutes,billing_interval,recurring,updated_by,archived_at) on public.catalog_items to authenticated;
grant select(variant_id,category_snapshot,accounting_code_snapshot,price_history_id,price_list_id) on public.document_lines to authenticated;
grant select(variant_id,transfer_group_id,lot_number,serial_number) on public.stock_movements to authenticated;

-- Les éléments antérieurs sont conservés tels quels : on documente seulement
-- leur passage au nouveau catalogue, sans inventer un faux historique de prix.
insert into public.item_activity_events(company_id,item_id,event_type,metadata,created_by,created_at)
select item.company_id,item.id,'catalog.migrated',jsonb_build_object('historical_price_history_available',false,'source','catalog_items'),item.created_by,now()
from public.catalog_items item
where not exists(select 1 from public.item_activity_events event where event.item_id=item.id and event.event_type in('item.created','catalog.migrated'));

insert into public.company_catalog_settings(company_id,created_by)
select id,owner_user_id from public.companies on conflict(company_id) do nothing;

commit;
