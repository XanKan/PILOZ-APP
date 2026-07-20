begin;

update public.company_settings set onboarding_completed_at=coalesce(onboarding_completed_at,updated_at,now())
where onboarding_completed_at is null and nullif(trim(legal_name),'') is not null and nullif(trim(siret),'') is not null
 and nullif(trim(email),'') is not null and nullif(trim(address_line1),'') is not null and nullif(trim(postal_code),'') is not null and nullif(trim(city),'') is not null;

create or replace function public.is_company_onboarded(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.company_settings settings join public.company_document_settings documents using(company_id)
  where settings.company_id=target_company_id and settings.onboarding_completed_at is not null
   and nullif(trim(settings.legal_name),'') is not null and nullif(trim(settings.siret),'') is not null
   and nullif(trim(settings.email),'') is not null and nullif(trim(settings.address_line1),'') is not null
   and nullif(trim(settings.postal_code),'') is not null and nullif(trim(settings.city),'') is not null
   and nullif(trim(documents.quote_prefix),'') is not null and nullif(trim(documents.invoice_prefix),'') is not null);
$$;
revoke all on function public.is_company_onboarded(uuid) from public;
grant execute on function public.is_company_onboarded(uuid) to authenticated;

alter table public.company_document_settings add column if not exists order_prefix text default 'CMD';
alter table public.company_document_settings add column if not exists delivery_prefix text default 'BL';
alter table public.company_document_settings add column if not exists purchase_order_prefix text default 'BCF';
alter table public.company_document_settings add column if not exists document_language text default 'fr';
alter table public.company_document_settings add column if not exists default_quote_template_id uuid references public.document_templates(id);
alter table public.company_document_settings add column if not exists default_invoice_template_id uuid references public.document_templates(id);

alter table public.company_settings add column if not exists department text;
alter table public.company_settings add column if not exists region text;
alter table public.company_settings add column if not exists establishment_kind text;
alter table public.company_settings add column if not exists administrative_status text;

alter table public.documents add column if not exists sale_type text;
alter table public.documents add column if not exists opportunity_id uuid references public.opportunities(id);
alter table public.documents add column if not exists assigned_user_id uuid;
alter table public.documents add column if not exists template_id uuid references public.document_templates(id);
alter table public.documents add column if not exists deposit_rate numeric(5,2) default 0 check(deposit_rate between 0 and 100);
alter table public.documents add column if not exists metadata jsonb not null default '{}'::jsonb;

-- New writes are bounded even when historical rows need to be cleaned separately.
alter table public.documents add constraint documents_discount_rate_range check(discount_rate between 0 and 100) not valid;
alter table public.document_lines add constraint document_lines_discount_rate_range check(discount_rate between 0 and 100) not valid;
alter table public.document_lines add constraint document_lines_tax_rate_range check(tax_rate between 0 and 100) not valid;
alter table public.document_lines add constraint document_lines_prices_nonnegative check(unit_cost_snapshot>=0 and unit_price>=0) not valid;
alter table public.catalog_items add constraint catalog_items_tax_rate_range check(tax_rate between 0 and 100) not valid;
alter table public.catalog_items add constraint catalog_items_prices_nonnegative check(purchase_price>=0 and landing_cost>=0 and cost_price>=0 and sale_price>=0) not valid;

create table if not exists public.company_erp_settings(
 company_id uuid primary key references public.companies(id) on delete cascade,
 valuation_method text not null default 'weighted_average' check(valuation_method in('weighted_average','fifo','standard','last_purchase')),
 allow_negative_stock boolean not null default false,
 reservation_policy text not null default 'confirmed_order',
 inventory_approval_required boolean not null default true,
 default_supplier_terms text,
 receipt_tolerance_percent numeric(5,2) not null default 0 check(receipt_tolerance_percent between 0 and 100),
 replenishment_horizon_days integer not null default 30 check(replenishment_horizon_days between 1 and 365),
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

create table if not exists public.supplier_quote_requests(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 number text not null,
 supplier_id uuid not null references public.suppliers(id),
 request_date date not null default current_date,
 response_due_date date,
 status text not null default 'draft' check(status in('draft','to_send','sent','responded','accepted','rejected','cancelled')),
 currency text not null default 'EUR',
 notes text,
 created_by uuid default auth.uid(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(company_id,number)
);

create table if not exists public.supplier_quote_request_lines(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 request_id uuid not null references public.supplier_quote_requests(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id),
 quantity numeric(15,4) not null check(quantity>0),
 target_unit_price numeric(15,4),
 quoted_unit_price numeric(15,4),
 supplier_reference text,
 notes text,
 created_by uuid default auth.uid(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.supplier_returns(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 number text not null,
 supplier_id uuid not null references public.suppliers(id),
 warehouse_id uuid not null references public.warehouses(id),
 goods_receipt_id uuid references public.goods_receipts(id),
 status text not null default 'draft' check(status in('draft','validated','cancelled')),
 reason text not null,
 returned_at timestamptz,
 created_by uuid default auth.uid(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(company_id,number)
);

create table if not exists public.supplier_return_lines(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 supplier_return_id uuid not null references public.supplier_returns(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id),
 location_id uuid references public.warehouse_locations(id),
 quantity numeric(15,4) not null check(quantity>0),
 unit_cost numeric(15,4) not null default 0,
 item_condition text not null default 'returnable' check(item_condition in('returnable','damaged','nonconforming')),
 comment text,
 created_by uuid default auth.uid(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create index if not exists supplier_quote_requests_company_status_idx on public.supplier_quote_requests(company_id,status,response_due_date);
create index if not exists supplier_returns_company_status_idx on public.supplier_returns(company_id,status,created_at);

create or replace function public.has_company_permission(target_company_id uuid,target_permission text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(
  select 1 from public.company_members member
  where member.company_id=target_company_id and member.user_id=auth.uid()
   and (member.role in('owner','admin') or coalesce((member.permissions->>target_permission)::boolean,false))
 );
$$;
revoke all on function public.has_company_permission(uuid,text) from public;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

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
  'movements',case when can_purchase then coalesce((select jsonb_agg(jsonb_build_object('id',id,'unit_cost',unit_cost,'total_value',total_value)) from public.stock_movements where company_id=target_company_id),'[]'::jsonb) else '[]'::jsonb end
 );
end $$;
revoke all on function public.get_company_financial_fields(uuid) from public;
grant execute on function public.get_company_financial_fields(uuid) to authenticated;

create or replace function public.protect_catalog_costs()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_company_permission(new.company_id,'view_purchase_prices') then
  if tg_op='UPDATE' then new.purchase_price:=old.purchase_price;new.landing_cost:=old.landing_cost;new.cost_price:=old.cost_price;
  else new.purchase_price:=0;new.landing_cost:=0;new.cost_price:=0;
  end if;
 end if;
 return new;
end $$;
create trigger catalog_items_protect_costs before insert or update on public.catalog_items
for each row execute function public.protect_catalog_costs();

create or replace function public.protect_stock_movement_cost()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_company_permission(new.company_id,'view_purchase_prices') then select item.cost_price into new.unit_cost from public.catalog_items item where item.id=new.item_id and item.company_id=new.company_id; end if;
 return new;
end $$;
create trigger stock_movements_protect_cost before insert or update on public.stock_movements
for each row execute function public.protect_stock_movement_cost();

-- Cost snapshots and commercial totals are authoritative database values. Members
-- without purchase-price access cannot inject an arbitrary item cost.
create or replace function public.calculate_document_line_amounts()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_company_permission(new.company_id,'view_purchase_prices') then
  if new.item_id is null then new.unit_cost_snapshot:=0;
  else select item.cost_price into new.unit_cost_snapshot from public.catalog_items item where item.id=new.item_id and item.company_id=new.company_id;
  end if;
 end if;
 if new.line_type in('item','free_item','discount') then
  new.total_excl_tax:=round((new.quantity*new.unit_price*(1-new.discount_rate/100))::numeric,2);
  new.total_tax:=round((new.total_excl_tax*new.tax_rate/100)::numeric,2);
  new.total_incl_tax:=new.total_excl_tax+new.total_tax;
 else
  new.total_excl_tax:=0;new.total_tax:=0;new.total_incl_tax:=0;
 end if;
 return new;
end $$;

create or replace function public.calculate_document_totals()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare raw_cost numeric;raw_ht numeric;raw_tax numeric;ratio numeric;
begin
 select coalesce(sum(line.quantity*line.unit_cost_snapshot),0),coalesce(sum(line.total_excl_tax),0),coalesce(sum(line.total_tax),0)
 into raw_cost,raw_ht,raw_tax from public.document_lines line where line.document_id=new.id and not line.optional;
 ratio:=case when raw_ht=0 then 1 else greatest(0,1-new.discount_rate/100) end;
 new.total_cost:=round(raw_cost,2);new.total_excl_tax:=round(raw_ht*ratio,2);new.total_tax:=round(raw_tax*ratio,2);
 new.total_incl_tax:=new.total_excl_tax+new.total_tax;
 return new;
end $$;

create or replace function public.sync_document_totals_from_lines()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare target_id uuid;
begin
 target_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
 update public.documents set updated_at=now() where id=target_id;
 if tg_op='DELETE' then return old; end if;return new;
end $$;

create trigger document_lines_calculate_amounts before insert or update on public.document_lines
for each row execute function public.calculate_document_line_amounts();
create trigger documents_calculate_totals before insert or update on public.documents
for each row execute function public.calculate_document_totals();
create trigger document_lines_sync_totals after insert or update or delete on public.document_lines
for each row execute function public.sync_document_totals_from_lines();

create or replace function public.confirm_company_email_token(target_company_id uuid,target_token_hash text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare verification public.company_contact_verifications%rowtype;
begin
 if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
 select * into verification from public.company_contact_verifications
 where company_id=target_company_id and channel='email' and token_hash=target_token_hash and consumed_at is null and expires_at>now()
 for update;
 if verification.id is null then return null; end if;
 update public.company_contact_verifications set consumed_at=now() where id=verification.id;
 update public.company_settings set email=verification.destination,email_confirmed_at=now() where company_id=target_company_id;
 return verification.destination;
end $$;

create or replace function public.confirm_company_phone_code(target_company_id uuid,target_token_hash text)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare verification public.company_contact_verifications%rowtype;
begin
 if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
 select * into verification from public.company_contact_verifications
 where company_id=target_company_id and channel='sms' and consumed_at is null and expires_at>now()
 order by created_at desc limit 1 for update;
 if verification.id is null or verification.attempts>=5 then return null; end if;
 if verification.token_hash<>target_token_hash then
  update public.company_contact_verifications set attempts=attempts+1 where id=verification.id;
  return null;
 end if;
 update public.company_contact_verifications set consumed_at=now() where id=verification.id;
 update public.company_settings set phone_e164=verification.destination,phone_verified_at=now() where company_id=target_company_id;
 return verification.destination;
end $$;

revoke all on function public.confirm_company_email_token(uuid,text),public.confirm_company_phone_code(uuid,text) from public;
grant execute on function public.confirm_company_email_token(uuid,text),public.confirm_company_phone_code(uuid,text) to authenticated;
-- Verification hashes are server-only (especially the six-digit SMS challenge).
drop policy if exists company_contact_verifications_select on public.company_contact_verifications;

drop policy if exists document_templates_insert on public.document_templates;
drop policy if exists document_templates_update on public.document_templates;
drop policy if exists document_templates_delete on public.document_templates;
create policy document_templates_insert_admin on public.document_templates for insert to authenticated
 with check(public.has_company_role(company_id,array['owner','admin']) and created_by=auth.uid());
create policy document_templates_update_admin on public.document_templates for update to authenticated
 using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));
create policy document_templates_delete_admin on public.document_templates for delete to authenticated
 using(public.has_company_role(company_id,array['owner','admin']));
drop policy if exists document_template_versions_insert on public.document_template_versions;
drop policy if exists document_template_versions_delete on public.document_template_versions;

drop policy if exists document_sequences_insert on public.document_sequences;
drop policy if exists document_sequences_update on public.document_sequences;
drop policy if exists document_sequences_delete on public.document_sequences;
create policy document_sequences_insert_admin on public.document_sequences for insert to authenticated
 with check(public.has_company_role(company_id,array['owner','admin']) and created_by=auth.uid());
create policy document_sequences_update_admin on public.document_sequences for update to authenticated
 using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));
create policy document_sequences_delete_admin on public.document_sequences for delete to authenticated
 using(public.has_company_role(company_id,array['owner','admin']));

create or replace function public.save_document_template_version(
 target_company_id uuid,target_user_id uuid,target_template_id uuid,target_name text,target_document_type text,target_language text,
 target_status text,target_is_default boolean,target_visual_schema jsonb,target_html text,target_css text,target_comment text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare template_id uuid; next_version integer;
begin
 if not exists(select 1 from public.company_members where company_id=target_company_id and user_id=target_user_id and role in('owner','admin'))
 then raise exception 'forbidden' using errcode='42501'; end if;
 if nullif(trim(target_name),'') is null then raise exception 'template_name_required'; end if;
 if target_is_default then
  update public.document_templates set is_default=false,updated_at=now(),updated_by=target_user_id
  where company_id=target_company_id and document_type=target_document_type and language=target_language and is_default;
 end if;
 if target_template_id is null then
  insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
  values(target_company_id,target_name,target_document_type,target_language,target_status,target_is_default,1,target_user_id,target_user_id)
  returning id,current_version into template_id,next_version;
 else
  select id,current_version+1 into template_id,next_version from public.document_templates
  where id=target_template_id and company_id=target_company_id for update;
  if template_id is null then raise exception 'template_not_found'; end if;
  update public.document_templates set name=target_name,document_type=target_document_type,language=target_language,status=target_status,
   is_default=target_is_default,current_version=next_version,updated_by=target_user_id,updated_at=now() where id=template_id;
 end if;
 insert into public.document_template_versions(company_id,template_id,version,visual_schema,html,css,change_comment,created_by)
 values(target_company_id,template_id,next_version,coalesce(target_visual_schema,'{}'::jsonb),coalesce(target_html,''),coalesce(target_css,''),coalesce(target_comment,'Nouvelle version'),target_user_id);
 return jsonb_build_object('templateId',template_id,'version',next_version);
end $$;

revoke all on function public.save_document_template_version(uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text) from public;
grant execute on function public.save_document_template_version(uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text) to service_role;

do $policies$
declare table_name text;
begin
 foreach table_name in array array['company_erp_settings','supplier_quote_requests','supplier_quote_request_lines','supplier_returns','supplier_return_lines'] loop
  execute format('alter table public.%I enable row level security',table_name);
  execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
  execute format('create policy %I on public.%I for insert to authenticated with check(public.is_company_member(company_id) and created_by=auth.uid())',table_name||'_insert',table_name);
  execute format('create policy %I on public.%I for update to authenticated using(public.is_company_member(company_id)) with check(public.is_company_member(company_id))',table_name||'_update',table_name);
  execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete',table_name);
 end loop;
end $policies$;

do $triggers$
declare table_name text;
begin
 foreach table_name in array array['company_erp_settings','supplier_quote_requests','supplier_quote_request_lines','supplier_returns','supplier_return_lines'] loop
  execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
 end loop;
end $triggers$;

drop policy if exists company_erp_settings_insert on public.company_erp_settings;
drop policy if exists company_erp_settings_update on public.company_erp_settings;
drop policy if exists company_erp_settings_delete on public.company_erp_settings;
create policy company_erp_settings_insert_admin on public.company_erp_settings for insert to authenticated
 with check(public.has_company_role(company_id,array['owner','admin']) and created_by=auth.uid());
create policy company_erp_settings_update_admin on public.company_erp_settings for update to authenticated
 using(public.has_company_role(company_id,array['owner','admin'])) with check(public.has_company_role(company_id,array['owner','admin']));
create policy company_erp_settings_delete_admin on public.company_erp_settings for delete to authenticated
 using(public.has_company_role(company_id,array['owner','admin']));

-- Purchase-domain rows, including their prices, are not readable or writable by
-- a role that lacks the explicit purchase-price permission.
do $purchase_policies$
declare table_name text;
begin
 foreach table_name in array array['supplier_items','purchase_orders','purchase_order_lines','goods_receipts','goods_receipt_lines','supplier_quote_requests','supplier_quote_request_lines','supplier_returns','supplier_return_lines'] loop
  execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
  execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
  execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
  execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
  execute format('create policy %I on public.%I for select to authenticated using(public.has_company_permission(company_id,''view_purchase_prices''))',table_name||'_select_authorized',table_name);
  execute format('create policy %I on public.%I for insert to authenticated with check(public.has_company_permission(company_id,''view_purchase_prices'') and created_by=auth.uid())',table_name||'_insert_authorized',table_name);
  execute format('create policy %I on public.%I for update to authenticated using(public.has_company_permission(company_id,''view_purchase_prices'')) with check(public.has_company_permission(company_id,''view_purchase_prices''))',table_name||'_update_authorized',table_name);
  execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',table_name||'_delete_admin',table_name);
 end loop;
end $purchase_policies$;

create or replace function public.confirm_purchase_order(target_order_id uuid)
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.purchase_orders%rowtype;confirmed_number text;
begin
 select * into target from public.purchase_orders where id=target_order_id for update;
 if target.id is null or target.status<>'draft' then raise exception 'invalid_purchase_order_state'; end if;
 if not public.has_company_permission(target.company_id,'view_purchase_prices') then raise exception 'forbidden' using errcode='42501'; end if;
 if not exists(select 1 from public.purchase_order_lines where purchase_order_id=target.id) then raise exception 'purchase_order_empty'; end if;
 update public.purchase_orders set status='confirmed',number=coalesce(number,public.next_document_number(target.company_id,'purchase_order')) where id=target.id returning number into confirmed_number;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(target.company_id,'purchase_order.confirmed','purchase_order',target.id);
 return confirmed_number;
end $$;
revoke all on function public.confirm_purchase_order(uuid) from public;
grant execute on function public.confirm_purchase_order(uuid) to authenticated;

-- A validated stock ledger cannot be altered directly. Manual entries require the
-- dedicated permission; workflow RPCs remain atomic and bypass these direct-write policies.
drop policy if exists stock_movements_insert on public.stock_movements;
drop policy if exists stock_movements_update on public.stock_movements;
create policy stock_movements_insert_authorized on public.stock_movements for insert to authenticated
 with check(public.has_company_permission(company_id,'adjust_stock') and created_by=auth.uid());
create policy stock_movements_update_draft_authorized on public.stock_movements for update to authenticated
 using(status='draft' and public.has_company_permission(company_id,'adjust_stock'))
 with check(status='draft' and public.has_company_permission(company_id,'adjust_stock'));

create or replace function public.protect_validated_document()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if old.validated_at is not null and
    (to_jsonb(new)-array['status','archived_at','updated_at']::text[]) is distinct from
    (to_jsonb(old)-array['status','archived_at','updated_at']::text[])
 then raise exception 'validated_document_is_locked' using errcode='55000'; end if;
 return new;
end $$;
create trigger documents_protect_validated before update on public.documents
for each row execute function public.protect_validated_document();

create or replace function public.protect_validated_document_line()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare target_document_id uuid;
begin
 target_document_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
 if exists(select 1 from public.documents where id=target_document_id and validated_at is not null)
 then raise exception 'validated_document_lines_are_locked' using errcode='55000'; end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger document_lines_protect_validated before insert or update or delete on public.document_lines
for each row execute function public.protect_validated_document_line();

-- Workflow statuses that create ledger effects can only be reached through the
-- SECURITY DEFINER RPCs above, never by a direct REST update.
create or replace function public.enforce_atomic_workflow_status()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare privileged boolean:=current_user in('postgres','service_role','supabase_admin');
begin
 if old.status='validated' and new.status is distinct from old.status then raise exception 'validated_workflow_is_immutable' using errcode='55000'; end if;
 if privileged then return new; end if;
 if tg_table_name='documents' and (
   (new.document_type in('invoice','deposit_invoice','credit_note') and new.status='validated' and old.status is distinct from new.status)
   or (new.document_type='sales_order' and new.status in('confirmed','partially_delivered','delivered','cancelled') and old.status is distinct from new.status)
  ) then raise exception 'workflow_rpc_required' using errcode='42501'; end if;
 if tg_table_name='purchase_orders' and new.status in('confirmed','partially_received','received') and old.status is distinct from new.status then raise exception 'workflow_rpc_required' using errcode='42501'; end if;
 if tg_table_name in('deliveries','goods_receipts','inventory_counts','supplier_returns') and new.status='validated' and old.status is distinct from new.status then raise exception 'workflow_rpc_required' using errcode='42501'; end if;
 return new;
end $$;

create trigger documents_enforce_atomic_status before update on public.documents
for each row execute function public.enforce_atomic_workflow_status();
create trigger purchase_orders_enforce_atomic_status before update on public.purchase_orders
for each row execute function public.enforce_atomic_workflow_status();
create trigger deliveries_enforce_atomic_status before update on public.deliveries
for each row execute function public.enforce_atomic_workflow_status();
create trigger goods_receipts_enforce_atomic_status before update on public.goods_receipts
for each row execute function public.enforce_atomic_workflow_status();
create trigger inventory_counts_enforce_atomic_status before update on public.inventory_counts
for each row execute function public.enforce_atomic_workflow_status();
create trigger supplier_returns_enforce_atomic_status before update on public.supplier_returns
for each row execute function public.enforce_atomic_workflow_status();

create or replace function public.protect_workflow_line()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare row_value jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;locked boolean:=false;
begin
 if tg_table_name='delivery_lines' then select status='validated' into locked from public.deliveries where id=(row_value->>'delivery_id')::uuid;
 elsif tg_table_name='goods_receipt_lines' then select status='validated' into locked from public.goods_receipts where id=(row_value->>'goods_receipt_id')::uuid;
 elsif tg_table_name='inventory_count_lines' then select status='validated' into locked from public.inventory_counts where id=(row_value->>'inventory_count_id')::uuid;
 elsif tg_table_name='supplier_return_lines' then select status='validated' into locked from public.supplier_returns where id=(row_value->>'supplier_return_id')::uuid;
 elsif tg_table_name='purchase_order_lines' and current_user not in('postgres','service_role','supabase_admin') then select status<>'draft' into locked from public.purchase_orders where id=(row_value->>'purchase_order_id')::uuid;
 end if;
 if coalesce(locked,false) then raise exception 'workflow_lines_are_locked' using errcode='55000'; end if;
 if tg_op='DELETE' then return old; end if;return new;
end $$;

create trigger delivery_lines_protect before insert or update or delete on public.delivery_lines
for each row execute function public.protect_workflow_line();
create trigger goods_receipt_lines_protect before insert or update or delete on public.goods_receipt_lines
for each row execute function public.protect_workflow_line();
create trigger inventory_count_lines_protect before insert or update or delete on public.inventory_count_lines
for each row execute function public.protect_workflow_line();
create trigger supplier_return_lines_protect before insert or update or delete on public.supplier_return_lines
for each row execute function public.protect_workflow_line();
create trigger purchase_order_lines_protect before insert or update or delete on public.purchase_order_lines
for each row execute function public.protect_workflow_line();

create or replace function public.protect_company_owner_role()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' and new.role='owner' and current_user not in('postgres','service_role','supabase_admin') then raise exception 'owner_role_cannot_be_assigned' using errcode='42501'; end if;
 if tg_op='DELETE' then
  if old.role='owner' and current_user not in('postgres','service_role','supabase_admin') then raise exception 'owner_role_cannot_be_removed' using errcode='42501'; end if;
  return old;
 end if;
 if old.role='owner' and new.role<>'owner' then raise exception 'owner_role_cannot_be_removed' using errcode='42501'; end if;
 if old.role<>'owner' and new.role='owner' then raise exception 'owner_role_cannot_be_assigned' using errcode='42501'; end if;
 return new;
end $$;
create trigger company_members_protect_owner before insert or update or delete on public.company_members
for each row execute function public.protect_company_owner_role();

create or replace function public.reset_company_contact_confirmation()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if new.email is distinct from old.email and new.email_confirmed_at is not distinct from old.email_confirmed_at then new.email_confirmed_at=null; end if;
 if new.phone_e164 is distinct from old.phone_e164 and new.phone_verified_at is not distinct from old.phone_verified_at then new.phone_verified_at=null; end if;
 return new;
end $$;
create trigger company_settings_reset_contact_confirmation before update on public.company_settings
for each row execute function public.reset_company_contact_confirmation();

create or replace function public.require_company_onboarding()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if not public.is_company_onboarded(new.company_id) then raise exception 'company_onboarding_required' using errcode='42501'; end if;
 return new;
end $$;
create trigger documents_require_onboarding before insert on public.documents
for each row execute function public.require_company_onboarding();
create trigger stock_movements_require_onboarding before insert on public.stock_movements
for each row execute function public.require_company_onboarding();
create trigger stock_reservations_require_onboarding before insert on public.stock_reservations
for each row execute function public.require_company_onboarding();
create trigger purchase_orders_require_onboarding before insert on public.purchase_orders
for each row execute function public.require_company_onboarding();
create trigger goods_receipts_require_onboarding before insert on public.goods_receipts
for each row execute function public.require_company_onboarding();
create trigger supplier_quote_requests_require_onboarding before insert on public.supplier_quote_requests
for each row execute function public.require_company_onboarding();
create trigger supplier_returns_require_onboarding before insert on public.supplier_returns
for each row execute function public.require_company_onboarding();

create or replace function public.prevent_negative_stock()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare allow_negative boolean; available numeric;
begin
 if new.from_warehouse_id is null then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.item_id::text||':'||new.from_warehouse_id::text,0));
 select coalesce(settings.allow_negative_stock,false) into allow_negative from public.company_erp_settings settings where settings.company_id=new.company_id;
 if allow_negative then return new; end if;
 select coalesce(sum(level.physical_quantity),0) into available from public.stock_levels level
 where level.company_id=new.company_id and level.item_id=new.item_id and level.warehouse_id=new.from_warehouse_id
  and (new.from_location_id is null or level.location_id=new.from_location_id);
 if available<new.quantity then raise exception 'negative_stock_forbidden:%',new.item_id; end if;
 return new;
end $$;
create trigger stock_movements_prevent_negative before insert on public.stock_movements
for each row execute function public.prevent_negative_stock();

create or replace function public.audit_erp_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare cid uuid; eid uuid; old_value jsonb; new_value jsonb;
begin
 old_value:=case when tg_op in('UPDATE','DELETE') then to_jsonb(old) else null end;
 new_value:=case when tg_op in('INSERT','UPDATE') then to_jsonb(new) else null end;
 cid:=coalesce((new_value->>'company_id')::uuid,(old_value->>'company_id')::uuid);
 eid:=coalesce((new_value->>'id')::uuid,(old_value->>'id')::uuid);
 insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
 values(cid,auth.uid(),lower(tg_table_name||'.'||tg_op),tg_table_name,eid,old_value,new_value,auth.uid());
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;

do $audit$
declare table_name text;
begin
 foreach table_name in array array['documents','document_lines','catalog_items','clients','suppliers','stock_movements','stock_reservations','inventory_counts','purchase_orders','goods_receipts','supplier_quote_requests','supplier_returns'] loop
  execute format('create trigger %I after insert or update or delete on public.%I for each row execute function public.audit_erp_change()',table_name||'_audit',table_name);
 end loop;
end $audit$;
drop policy if exists activity_logs_insert on public.activity_logs;
drop policy if exists activity_logs_select on public.activity_logs;
create policy activity_logs_select_admin on public.activity_logs for select to authenticated
 using(public.has_company_role(company_id,array['owner','admin']));
drop policy if exists stock_cost_history_select on public.stock_cost_history;
create policy stock_cost_history_select_authorized on public.stock_cost_history for select to authenticated
 using(public.has_company_permission(company_id,'view_purchase_prices'));

-- PostgreSQL column privileges prevent an authenticated client from bypassing
-- the role-aware UI with a direct `select=*` REST call.
revoke select on table public.catalog_items,public.documents,public.document_lines,public.stock_movements from anon,authenticated;
grant select(id,company_id,item_type,reference,barcode,name,short_description,sales_description,category,subcategory,brand,unit,image_path,sale_price,tax_rate,minimum_price,stock_managed,minimum_stock,maximum_stock,reorder_point,valuation_method,active,created_by,created_at,updated_at) on public.catalog_items to authenticated;
grant select(id,company_id,document_type,number,version,client_id,supplier_id,status,issue_date,due_date,subject,client_reference,currency,language,payment_terms,payment_method,internal_notes,public_notes,discount_rate,total_excl_tax,total_tax,total_incl_tax,source_document_id,validated_at,archived_at,created_by,created_at,updated_at,sale_type,opportunity_id,assigned_user_id,template_id,deposit_rate,metadata) on public.documents to authenticated;
grant select(id,company_id,document_id,position,line_type,section_id,item_id,reference,name,description,quantity,unit,unit_price,discount_rate,tax_rate,optional,total_excl_tax,total_tax,total_incl_tax,created_by,created_at,updated_at) on public.document_lines to authenticated;
grant select(id,company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,to_warehouse_id,to_location_id,occurred_at,source_type,source_id,reason,comment,attachment_path,reversal_of,status,created_by,created_at,updated_at) on public.stock_movements to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('company-files','company-files',false,10485760,array['application/pdf','image/png','image/jpeg','text/plain','text/csv'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy company_files_select on storage.objects for select to authenticated using(
 bucket_id='company-files' and public.is_company_member((storage.foldername(name))[1]::uuid)
);
create policy company_files_insert on storage.objects for insert to authenticated with check(
 bucket_id='company-files' and (public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin']) or public.has_company_permission((storage.foldername(name))[1]::uuid,'adjust_stock'))
);
create policy company_files_update on storage.objects for update to authenticated using(
 bucket_id='company-files' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
) with check(bucket_id='company-files' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin']));
create policy company_files_delete on storage.objects for delete to authenticated using(
 bucket_id='company-files' and public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
);

create or replace function public.validate_supplier_return(target_return_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.supplier_returns%rowtype; line record; available numeric;
begin
 select * into target from public.supplier_returns where id=target_return_id for update;
 if target.id is null or target.status<>'draft' then raise exception 'invalid_supplier_return_state'; end if;
 if not public.has_company_role(target.company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
 for line in select * from public.supplier_return_lines where supplier_return_id=target.id loop
  select coalesce(sum(physical_quantity),0) into available
  from public.stock_levels
  where item_id=line.item_id and warehouse_id=target.warehouse_id and (line.location_id is null or location_id=line.location_id);
  if available<line.quantity then raise exception 'insufficient_stock:%',line.item_id; end if;
  insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,source_type,source_id,reason,unit_cost,status)
  select target.company_id,line.item_id,'supplier_return',line.quantity,item.unit,target.warehouse_id,line.location_id,'supplier_return',target.id,target.reason,line.unit_cost,'validated'
  from public.catalog_items item where item.id=line.item_id and item.stock_managed;
 end loop;
 if not exists(select 1 from public.supplier_return_lines where supplier_return_id=target.id) then raise exception 'supplier_return_empty'; end if;
 update public.supplier_returns set status='validated',returned_at=now() where id=target.id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data)
 values(target.company_id,'supplier_return.validated','supplier_return',target.id,jsonb_build_object('reason',target.reason));
end $$;

revoke all on function public.validate_supplier_return(uuid) from public;
grant execute on function public.validate_supplier_return(uuid) to authenticated;

commit;
