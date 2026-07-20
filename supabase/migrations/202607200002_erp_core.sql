begin;

create extension if not exists pgcrypto;

-- Helpers are SECURITY DEFINER to avoid recursive company_members RLS checks.
create or replace function public.is_company_member(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.company_members m where m.company_id=target_company_id and m.user_id=auth.uid());
$$;
create or replace function public.has_company_role(target_company_id uuid, allowed_roles text[])
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.company_members m where m.company_id=target_company_id and m.user_id=auth.uid() and m.role=any(allowed_roles));
$$;
revoke all on function public.is_company_member(uuid) from public;
revoke all on function public.has_company_role(uuid,text[]) from public;
grant execute on function public.is_company_member(uuid) to authenticated;
grant execute on function public.has_company_role(uuid,text[]) to authenticated;

alter table public.company_members add column if not exists permissions jsonb not null default '{"view_purchase_prices":false,"view_margins":false,"adjust_stock":false}'::jsonb;

drop policy if exists company_members_select_member on public.company_members;
drop policy if exists company_members_insert_owner on public.company_members;
create policy company_members_select_member on public.company_members for select to authenticated using(public.is_company_member(company_id));
create policy company_members_insert_admin on public.company_members for insert to authenticated with check(public.has_company_role(company_id,array['owner','admin']));
create policy company_members_update_admin on public.company_members for update to authenticated using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));
create policy company_members_delete_admin on public.company_members for delete to authenticated using(public.has_company_role(company_id,array['owner','admin']) and user_id<>auth.uid());

drop policy if exists company_settings_member_all on public.company_settings;
drop policy if exists company_document_settings_member_all on public.company_document_settings;
create policy company_settings_read on public.company_settings for select to authenticated using(public.is_company_member(company_id));
create policy company_settings_write on public.company_settings for all to authenticated using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));
create policy company_document_settings_read on public.company_document_settings for select to authenticated using(public.is_company_member(company_id));
create policy company_document_settings_write on public.company_document_settings for all to authenticated using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));

alter table public.company_settings add column if not exists siren text, add column if not exists activity text, add column if not exists creation_date date, add column if not exists establishment_kind text, add column if not exists country_code text default 'FR', add column if not exists latitude numeric(9,6), add column if not exists longitude numeric(9,6), add column if not exists data_source text, add column if not exists data_retrieved_at timestamptz, add column if not exists email_confirmed_at timestamptz, add column if not exists phone_e164 text, add column if not exists phone_verified_at timestamptz, add column if not exists website text, add column if not exists onboarding_step smallint not null default 1, add column if not exists onboarding_completed_at timestamptz;

create table if not exists public.company_addresses(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 kind text not null default 'registered' check(kind in('registered','billing','shipping','warehouse','other')),
 address_line_1 text, address_line_2 text, postal_code text, city text, country_code text not null default 'FR',
 department text, region text, latitude numeric(9,6), longitude numeric(9,6), source text, source_id text,
 is_primary boolean not null default false, created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists company_addresses_one_primary on public.company_addresses(company_id,kind) where is_primary;

create table if not exists public.company_logos(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 variant text not null check(variant in('light','dark')), storage_path text not null, mime_type text not null,
 size_bytes bigint not null check(size_bytes between 1 and 5242880), width integer, height integer, is_active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,variant,storage_path)
);
create unique index if not exists company_logos_active_variant on public.company_logos(company_id,variant) where is_active;

create table if not exists public.document_sequences(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 document_type text not null, prefix text not null, year integer, next_value bigint not null default 1 check(next_value>0), padding smallint not null default 4 check(padding between 1 and 12),
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,document_type,year)
);

create table if not exists public.clients(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 kind text not null default 'company' check(kind in('company','person')), legal_name text, first_name text, last_name text,
 email text, phone_e164 text, siren text, siret text, vat_number text, address_line_1 text, address_line_2 text,
 postal_code text, city text, country_code text default 'FR', language text default 'fr', payment_terms text, preferred_payment_method text,
 discount_rate numeric(5,2) not null default 0 check(discount_rate between 0 and 100), active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists clients_search_idx on public.clients(company_id,legal_name,email,siret,city);

create table if not exists public.suppliers(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 legal_name text not null, siret text, vat_number text, email text, phone_e164 text, address_line_1 text, address_line_2 text,
 postal_code text, city text, country_code text default 'FR', payment_terms text, average_lead_days integer, active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.catalog_items(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 item_type text not null check(item_type in('product','service','subscription','package')), reference text not null, barcode text,
 name text not null, short_description text, sales_description text, category text, subcategory text, brand text, unit text not null default 'unité', image_path text,
 purchase_price numeric(15,4) not null default 0, landing_cost numeric(15,4) not null default 0, cost_price numeric(15,4) not null default 0,
 sale_price numeric(15,4) not null default 0, tax_rate numeric(5,2) not null default 20, minimum_price numeric(15,4), stock_managed boolean not null default false,
 minimum_stock numeric(15,4) not null default 0, maximum_stock numeric(15,4), reorder_point numeric(15,4), valuation_method text not null default 'weighted_average', active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,reference),
 check(item_type<>'service' or stock_managed=false)
);

create table if not exists public.supplier_items(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 supplier_id uuid not null references public.suppliers(id), catalog_item_id uuid not null references public.catalog_items(id), supplier_reference text,
 purchase_price numeric(15,4), lead_days integer, minimum_order_quantity numeric(15,4), package_quantity numeric(15,4), is_primary boolean not null default false,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(supplier_id,catalog_item_id)
);

create table if not exists public.warehouses(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 code text not null, name text not null, address_id uuid references public.company_addresses(id), manager_user_id uuid, active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,code)
);
create table if not exists public.warehouse_locations(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade, warehouse_id uuid not null references public.warehouses(id) on delete cascade,
 code text not null, zone text, aisle text, rack text, shelf text, bin text, active boolean not null default true,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(warehouse_id,code)
);

create table if not exists public.stock_movements(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id), movement_type text not null,
 quantity numeric(15,4) not null check(quantity>0), unit text not null, from_warehouse_id uuid references public.warehouses(id), from_location_id uuid references public.warehouse_locations(id),
 to_warehouse_id uuid references public.warehouses(id), to_location_id uuid references public.warehouse_locations(id), occurred_at timestamptz not null default now(),
 source_type text, source_id uuid, reason text, unit_cost numeric(15,4) not null default 0, total_value numeric(15,4) generated always as(quantity*unit_cost) stored,
 comment text, attachment_path text, reversal_of uuid references public.stock_movements(id), status text not null default 'validated' check(status in('draft','validated','reversed')),
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists stock_movements_ledger_idx on public.stock_movements(company_id,item_id,occurred_at);

create table if not exists public.stock_reservations(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id), warehouse_id uuid not null references public.warehouses(id), location_id uuid references public.warehouse_locations(id),
 quantity numeric(15,4) not null check(quantity>0), source_type text not null, source_id uuid not null, status text not null default 'active' check(status in('active','released','consumed')),
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create or replace view public.stock_levels with (security_invoker=true) as
select i.company_id,i.id item_id,w.id warehouse_id,l.id location_id,
 coalesce(sum(case when m.status='validated' and m.to_warehouse_id=w.id and m.to_location_id is not distinct from l.id then m.quantity else 0 end),0)
 -coalesce(sum(case when m.status='validated' and m.from_warehouse_id=w.id and m.from_location_id is not distinct from l.id then m.quantity else 0 end),0) physical_quantity,
 coalesce((select sum(r.quantity) from public.stock_reservations r where r.item_id=i.id and r.warehouse_id=w.id and r.location_id is not distinct from l.id and r.status='active'),0) reserved_quantity
from public.catalog_items i join public.warehouses w on w.company_id=i.company_id left join public.warehouse_locations l on l.warehouse_id=w.id
left join public.stock_movements m on m.item_id=i.id and (m.from_warehouse_id=w.id or m.to_warehouse_id=w.id)
where i.stock_managed group by i.company_id,i.id,w.id,l.id;

create table if not exists public.documents(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 document_type text not null check(document_type in('quote','invoice','credit_note','sales_order','delivery_note','contract','purchase_order')),
 number text, version integer not null default 1, client_id uuid references public.clients(id), supplier_id uuid references public.suppliers(id), status text not null default 'draft',
 issue_date date not null default current_date, due_date date, subject text, client_reference text, currency text not null default 'EUR', language text not null default 'fr',
 payment_terms text, payment_method text, internal_notes text, public_notes text, discount_rate numeric(5,2) not null default 0,
 total_cost numeric(15,2) not null default 0, total_excl_tax numeric(15,2) not null default 0, total_tax numeric(15,2) not null default 0, total_incl_tax numeric(15,2) not null default 0,
 source_document_id uuid references public.documents(id), validated_at timestamptz, archived_at timestamptz,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(company_id,document_type,number)
);
create table if not exists public.document_lines(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade, document_id uuid not null references public.documents(id) on delete cascade,
 position integer not null, line_type text not null default 'item', section_id uuid, item_id uuid references public.catalog_items(id), reference text, name text, description text,
 quantity numeric(15,4) not null default 1, unit text, unit_cost_snapshot numeric(15,4) not null default 0, unit_price numeric(15,4) not null default 0,
 discount_rate numeric(5,2) not null default 0, tax_rate numeric(5,2) not null default 0, optional boolean not null default false,
 total_excl_tax numeric(15,2) not null default 0, total_tax numeric(15,2) not null default 0, total_incl_tax numeric(15,2) not null default 0,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(document_id,position)
);

create table if not exists public.document_templates(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
 name text not null, document_type text not null, language text not null default 'fr', status text not null default 'active', is_default boolean not null default false,
 current_version integer not null default 1, created_by uuid default auth.uid(), updated_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists document_templates_default_idx on public.document_templates(company_id,document_type,language) where is_default and status='active';
create table if not exists public.document_template_versions(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade, template_id uuid not null references public.document_templates(id) on delete cascade,
 version integer not null, visual_schema jsonb not null default '{}'::jsonb, html text not null default '', css text not null default '', change_comment text,
 created_by uuid default auth.uid(), created_at timestamptz not null default now(), unique(template_id,version)
);

create table if not exists public.purchase_orders(
 id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade, number text, supplier_id uuid not null references public.suppliers(id),
 warehouse_id uuid not null references public.warehouses(id), order_date date not null default current_date, expected_date date, status text not null default 'draft', currency text not null default 'EUR',
 total_excl_tax numeric(15,2) not null default 0,total_tax numeric(15,2) not null default 0,total_incl_tax numeric(15,2) not null default 0,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(company_id,number)
);
create table if not exists public.purchase_order_lines(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id),quantity numeric(15,4) not null check(quantity>0),received_quantity numeric(15,4) not null default 0,
 unit_price numeric(15,4) not null,discount_rate numeric(5,2) not null default 0,tax_rate numeric(5,2) not null default 0,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.goods_receipts(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,number text,purchase_order_id uuid references public.purchase_orders(id),
 warehouse_id uuid not null references public.warehouses(id),received_at timestamptz,status text not null default 'draft',
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(company_id,number)
);
create table if not exists public.goods_receipt_lines(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,goods_receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
 purchase_order_line_id uuid references public.purchase_order_lines(id),item_id uuid not null references public.catalog_items(id),location_id uuid references public.warehouse_locations(id),
 quantity numeric(15,4) not null check(quantity>0),unit_cost numeric(15,4) not null,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

create table if not exists public.inventory_counts(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,warehouse_id uuid references public.warehouses(id),name text not null,scope text not null,
 status text not null default 'draft',counted_at timestamptz,validated_at timestamptz,created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.inventory_count_lines(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,inventory_count_id uuid not null references public.inventory_counts(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id),location_id uuid references public.warehouse_locations(id),theoretical_quantity numeric(15,4) not null,counted_quantity numeric(15,4),
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

create table if not exists public.activity_logs(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,actor_user_id uuid default auth.uid(),action text not null,
 entity_type text not null,entity_id uuid,old_data jsonb,new_data jsonb,created_by uuid default auth.uid(),created_at timestamptz not null default now()
);

create or replace view public.stock_levels with (security_invoker=true) as
with movement_entries as (
 select company_id,item_id,to_warehouse_id warehouse_id,to_location_id location_id,quantity delta,case when movement_type='transfer_in_transit' then quantity else 0 end transit,0::numeric damaged from public.stock_movements where status='validated' and to_warehouse_id is not null
 union all
 select company_id,item_id,from_warehouse_id,from_location_id,-quantity,case when movement_type='transfer_in_transit' then quantity else 0 end,case when movement_type='damage' then quantity else 0 end from public.stock_movements where status='validated' and from_warehouse_id is not null
), movement_totals as (
 select company_id,item_id,warehouse_id,location_id,sum(delta) physical_quantity,sum(transit) in_transit_quantity,sum(damaged) damaged_quantity
 from movement_entries group by company_id,item_id,warehouse_id,location_id
), reservation_totals as (
 select company_id,item_id,warehouse_id,location_id,sum(quantity) reserved_quantity from public.stock_reservations where status='active' group by company_id,item_id,warehouse_id,location_id
), expected_totals as (
 select po.company_id,pol.item_id,po.warehouse_id,sum(greatest(pol.quantity-pol.received_quantity,0)) expected_quantity
 from public.purchase_orders po join public.purchase_order_lines pol on pol.purchase_order_id=po.id
 where po.status in('sent','confirmed','partially_received') group by po.company_id,pol.item_id,po.warehouse_id
)
select i.company_id,i.id item_id,w.id warehouse_id,l.id location_id,
 coalesce(mt.physical_quantity,0) physical_quantity,coalesce(rt.reserved_quantity,0) reserved_quantity,
 coalesce(mt.physical_quantity,0)-coalesce(rt.reserved_quantity,0) available_quantity,coalesce(et.expected_quantity,0) expected_quantity,
 coalesce(mt.in_transit_quantity,0) in_transit_quantity,coalesce(mt.damaged_quantity,0) damaged_quantity
from public.catalog_items i join public.warehouses w on w.company_id=i.company_id left join public.warehouse_locations l on l.warehouse_id=w.id
left join movement_totals mt on mt.item_id=i.id and mt.warehouse_id=w.id and mt.location_id is not distinct from l.id
left join reservation_totals rt on rt.item_id=i.id and rt.warehouse_id=w.id and rt.location_id is not distinct from l.id
left join expected_totals et on et.item_id=i.id and et.warehouse_id=w.id
where i.stock_managed;

create or replace function public.next_document_number(target_company_id uuid,target_type text,target_year integer default extract(year from current_date)::integer)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare seq public.document_sequences%rowtype; result text;
begin
 if not public.has_company_role(target_company_id,array['owner','admin','member']) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into public.document_sequences(company_id,document_type,prefix,year,next_value)
 values(target_company_id,target_type,upper(left(target_type,3)),target_year,1)
 on conflict(company_id,document_type,year) do nothing;
 select * into seq from public.document_sequences where company_id=target_company_id and document_type=target_type and year=target_year for update;
 result:=seq.prefix||'-'||target_year::text||'-'||lpad(seq.next_value::text,seq.padding,'0');
 update public.document_sequences set next_value=next_value+1,updated_at=now() where id=seq.id;
 return result;
end $$;
revoke all on function public.next_document_number(uuid,text,integer) from public;
grant execute on function public.next_document_number(uuid,text,integer) to authenticated;

-- Apply tenant RLS consistently to all newly normalized tables.
do $rls$
declare table_name text;
begin
 foreach table_name in array array['company_addresses','company_logos','document_sequences','clients','suppliers','catalog_items','supplier_items','warehouses','warehouse_locations','stock_movements','stock_reservations','documents','document_lines','document_templates','document_template_versions','purchase_orders','purchase_order_lines','goods_receipts','goods_receipt_lines','inventory_counts','inventory_count_lines','activity_logs']
 loop
  execute format('alter table public.%I enable row level security',table_name);
  execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
  execute format('create policy %I on public.%I for insert to authenticated with check(public.is_company_member(company_id) and created_by=auth.uid())',table_name||'_insert',table_name);
  execute format('create policy %I on public.%I for update to authenticated using(public.is_company_member(company_id)) with check(public.is_company_member(company_id))',table_name||'_update',table_name);
  execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
 end loop;
end $rls$;

do $triggers$
declare table_name text;
begin
 foreach table_name in array array['company_addresses','company_logos','document_sequences','clients','suppliers','catalog_items','supplier_items','warehouses','warehouse_locations','stock_movements','stock_reservations','documents','document_lines','document_templates','purchase_orders','purchase_order_lines','goods_receipts','goods_receipt_lines','inventory_counts','inventory_count_lines']
 loop
  execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
 end loop;
end $triggers$;

-- Immutable ledgers: validated movements and audit events are never edited away.
drop policy if exists stock_movements_delete on public.stock_movements;
create policy stock_movements_delete_draft on public.stock_movements for delete to authenticated
using(status='draft' and public.has_company_role(company_id,array['owner','admin']));
drop policy if exists activity_logs_update on public.activity_logs;
drop policy if exists activity_logs_delete on public.activity_logs;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('company-assets','company-assets',false,5242880,array['image/png','image/jpeg','image/svg+xml'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists company_assets_select on storage.objects;
drop policy if exists company_assets_insert on storage.objects;
drop policy if exists company_assets_update on storage.objects;
drop policy if exists company_assets_delete on storage.objects;
create policy company_assets_select on storage.objects for select to authenticated using(
 bucket_id='company-assets' and public.is_company_member((storage.foldername(name))[1]::uuid)
);
create policy company_assets_insert on storage.objects for insert to authenticated with check(
 bucket_id='company-assets' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);
create policy company_assets_update on storage.objects for update to authenticated using(
 bucket_id='company-assets' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
) with check(bucket_id='company-assets' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin']));
create policy company_assets_delete on storage.objects for delete to authenticated using(
 bucket_id='company-assets' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);

commit;
