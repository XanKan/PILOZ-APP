-- Suite commerciale moderne Piloz.
-- Migration additive : aucune table historique ni aucune donnée n'est supprimée.

alter table public.clients add column if not exists civility text;
alter table public.clients add column if not exists trade_name text;
alter table public.clients add column if not exists legal_form text;
alter table public.clients add column if not exists ape_code text;
alter table public.clients add column if not exists contact_name text;
alter table public.clients add column if not exists relationship_type text not null default 'client';
alter table public.clients drop constraint if exists clients_relationship_type_check;
alter table public.clients add constraint clients_relationship_type_check check (relationship_type in ('prospect','client','archived')) not valid;

alter table public.catalog_items add column if not exists category_id uuid;
alter table public.catalog_items add column if not exists primary_supplier_id uuid references public.suppliers(id);
alter table public.catalog_items add column if not exists supplier_reference text;
alter table public.catalog_items add column if not exists supply_lead_days integer;
alter table public.catalog_items add column if not exists default_warehouse_id uuid references public.warehouses(id);
alter table public.catalog_items add column if not exists default_location_id uuid references public.warehouse_locations(id);

alter table public.documents add column if not exists validity_date date;
alter table public.documents add column if not exists viewed_at timestamptz;
alter table public.documents add column if not exists last_reminder_at timestamptz;
alter table public.documents drop constraint if exists documents_document_type_check;
alter table public.documents add constraint documents_document_type_check check(document_type in(
  'quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice','recurring_invoice',
  'sales_order','delivery_note','contract','purchase_order','purchase_invoice','reminder','statement'
));
grant select(category_id,primary_supplier_id,supplier_reference,supply_lead_days,default_warehouse_id,default_location_id) on public.catalog_items to authenticated;
grant select(validity_date,viewed_at,last_reminder_at) on public.documents to authenticated;

alter table public.opportunities add column if not exists contact_id uuid;
alter table public.opportunities add column if not exists expected_close_date date;
alter table public.opportunities add column if not exists closed_at timestamptz;
alter table public.opportunities add column if not exists lost_reason text;
alter table public.opportunities add column if not exists assigned_user_id uuid;

alter table public.company_erp_settings add column if not exists crm_automations jsonb not null default '{"quote_created":true,"quote_sent":true,"quote_accepted":true,"quote_rejected":true,"invoice_created":true,"invoice_paid":true}'::jsonb;
alter table public.company_erp_settings add column if not exists accounting_settings jsonb not null default '{}'::jsonb;
alter table public.company_erp_settings add column if not exists sales_settings jsonb not null default '{}'::jsonb;
alter table public.company_erp_settings add column if not exists purchase_settings jsonb not null default '{}'::jsonb;
alter table public.company_erp_settings add column if not exists stock_settings jsonb not null default '{}'::jsonb;

create table if not exists public.client_contacts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  civility text, first_name text not null, last_name text not null, job_title text,
  email text, phone_e164 text, is_primary boolean not null default false,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists client_contacts_primary_idx on public.client_contacts(client_id) where is_primary;
create index if not exists client_contacts_company_client_idx on public.client_contacts(company_id,client_id);

create table if not exists public.catalog_categories(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  parent_id uuid references public.catalog_categories(id) on delete set null,
  name text not null, description text, active boolean not null default true,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,name)
);
do $$ begin
  if not exists(select 1 from pg_constraint where conname='catalog_items_category_fk') then
    alter table public.catalog_items add constraint catalog_items_category_fk foreign key(category_id) references public.catalog_categories(id) on delete set null;
  end if;
end $$;

create table if not exists public.vat_rates(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  rate numeric(5,2) not null check(rate between 0 and 100), label text not null,
  account_code text, valid_from date, valid_until date,
  is_default boolean not null default false, active boolean not null default true,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(valid_until is null or valid_from is null or valid_until>=valid_from)
);
create unique index if not exists vat_rates_identity_idx on public.vat_rates(company_id,rate,coalesce(valid_from,'1900-01-01'::date));
create unique index if not exists vat_rates_default_idx on public.vat_rates(company_id) where is_default and active;

create table if not exists public.pipeline_stages(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null, slug text not null, position integer not null default 0,
  probability numeric(5,2) not null default 0 check(probability between 0 and 100),
  color text not null default '#52606d', active boolean not null default true,
  is_won boolean not null default false, is_lost boolean not null default false,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,slug), check(not(is_won and is_lost))
);

create table if not exists public.activities(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opportunity_id uuid references public.opportunities(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  activity_type text not null default 'note' check(activity_type in('call','email','meeting','task','note','other')),
  subject text not null, description text, scheduled_at timestamptz, completed_at timestamptz,
  assigned_user_id uuid, metadata jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists activities_company_schedule_idx on public.activities(company_id,scheduled_at);
create index if not exists activities_opportunity_idx on public.activities(opportunity_id,created_at desc);

create table if not exists public.reminders(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  opportunity_id uuid references public.opportunities(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  document_id uuid references public.documents(id) on delete cascade,
  reminder_type text not null default 'commercial' check(reminder_type in('commercial','payment','quote','task')),
  subject text not null, message text, due_at timestamptz not null,
  completed_at timestamptz, assigned_user_id uuid, status text not null default 'pending' check(status in('pending','completed','cancelled')),
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists reminders_company_due_idx on public.reminders(company_id,status,due_at);

create table if not exists public.payment_schedules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_id uuid not null references public.documents(id) on delete cascade,
  due_date date not null, amount numeric(15,2) not null check(amount>=0), paid_amount numeric(15,2) not null default 0 check(paid_amount>=0),
  status text not null default 'pending' check(status in('pending','partial','paid','cancelled')),
  label text, created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(document_id,due_date,label)
);
create index if not exists payment_schedules_company_due_idx on public.payment_schedules(company_id,status,due_date);

create table if not exists public.dashboard_widgets(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null, widget_key text not null, position integer not null default 0,
  width integer not null default 1 check(width between 1 and 4), height integer not null default 1 check(height between 1 and 4),
  config jsonb not null default '{}'::jsonb,
  created_by uuid default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,user_id,widget_key)
);

do $rls$
declare t text;
begin
  foreach t in array array['client_contacts','catalog_categories','vat_rates','pipeline_stages','activities','reminders','payment_schedules','dashboard_widgets'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',t||'_select',t);
    execute format('create policy %I on public.%I for insert to authenticated with check(public.is_company_member(company_id) and created_by=auth.uid())',t||'_insert',t);
    execute format('create policy %I on public.%I for update to authenticated using(public.is_company_member(company_id)) with check(public.is_company_member(company_id))',t||'_update',t);
    execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',t||'_delete',t);
  end loop;
end $rls$;

drop policy if exists dashboard_widgets_insert on public.dashboard_widgets;
drop policy if exists dashboard_widgets_update on public.dashboard_widgets;
drop policy if exists dashboard_widgets_delete on public.dashboard_widgets;
create policy dashboard_widgets_insert on public.dashboard_widgets for insert to authenticated
  with check(public.is_company_member(company_id) and user_id=auth.uid() and created_by=auth.uid());
create policy dashboard_widgets_update on public.dashboard_widgets for update to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid())
  with check(public.is_company_member(company_id) and user_id=auth.uid());
create policy dashboard_widgets_delete on public.dashboard_widgets for delete to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid());

do $triggers$
declare t text;
begin
  foreach t in array array['client_contacts','catalog_categories','vat_rates','pipeline_stages','activities','reminders','payment_schedules','dashboard_widgets'] loop
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',t||'_set_updated_at',t);
  end loop;
end $triggers$;

insert into public.vat_rates(company_id,rate,label,is_default,created_by)
select c.id,v.rate,v.label,v.rate=20,c.owner_user_id
from public.companies c cross join(values(0::numeric,'Exonéré · 0 %'),(2.1,'Taux particulier · 2,1 %'),(5.5,'Taux réduit · 5,5 %'),(10,'Taux intermédiaire · 10 %'),(20,'Taux normal · 20 %'))v(rate,label)
on conflict do nothing;

insert into public.pipeline_stages(company_id,name,slug,position,probability,color,is_won,is_lost,created_by)
select c.id,v.name,v.slug,v.position,v.probability,v.color,v.is_won,v.is_lost,c.owner_user_id
from public.companies c cross join(values
 ('Prospection','prospecting',10,10::numeric,'#64748b',false,false),
 ('Qualification','qualification',20,25::numeric,'#2563eb',false,false),
 ('Devis en préparation','quote_preparation',30,40::numeric,'#7c3aed',false,false),
 ('Devis envoyé','quote_sent',40,60::numeric,'#d97706',false,false),
 ('Gagné','won',50,100::numeric,'#16a34a',true,false),
 ('Facturation','invoicing',60,85::numeric,'#0891b2',false,false),
 ('Encaissé','collected',70,100::numeric,'#15803d',true,false),
 ('Perdu','lost',80,0::numeric,'#b91c1c',false,true)
)v(name,slug,position,probability,color,is_won,is_lost)
on conflict do nothing;

create or replace function public.seed_company_commercial_defaults()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.vat_rates(company_id,rate,label,is_default,created_by) values
    (new.id,0,'Exonéré · 0 %',false,new.owner_user_id),(new.id,2.1,'Taux particulier · 2,1 %',false,new.owner_user_id),
    (new.id,5.5,'Taux réduit · 5,5 %',false,new.owner_user_id),(new.id,10,'Taux intermédiaire · 10 %',false,new.owner_user_id),
    (new.id,20,'Taux normal · 20 %',true,new.owner_user_id);
  insert into public.pipeline_stages(company_id,name,slug,position,probability,color,is_won,is_lost,created_by) values
    (new.id,'Prospection','prospecting',10,10,'#64748b',false,false,new.owner_user_id),
    (new.id,'Qualification','qualification',20,25,'#2563eb',false,false,new.owner_user_id),
    (new.id,'Devis en préparation','quote_preparation',30,40,'#7c3aed',false,false,new.owner_user_id),
    (new.id,'Devis envoyé','quote_sent',40,60,'#d97706',false,false,new.owner_user_id),
    (new.id,'Gagné','won',50,100,'#16a34a',true,false,new.owner_user_id),
    (new.id,'Facturation','invoicing',60,85,'#0891b2',false,false,new.owner_user_id),
    (new.id,'Encaissé','collected',70,100,'#15803d',true,false,new.owner_user_id),
    (new.id,'Perdu','lost',80,0,'#b91c1c',false,true,new.owner_user_id);
  return new;
end $$;
drop trigger if exists companies_seed_commercial_defaults on public.companies;
create trigger companies_seed_commercial_defaults after insert on public.companies for each row execute function public.seed_company_commercial_defaults();

create or replace function public.convert_quote_to_invoice(target_quote_id uuid,target_invoice_type text default 'invoice')
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; target_id uuid;
begin
  if target_invoice_type not in('invoice','deposit_invoice','proforma_invoice') then raise exception 'invalid_invoice_type'; end if;
  select * into source from public.documents where id=target_quote_id for update;
  if source.id is null or source.document_type<>'quote' then raise exception 'quote_not_found'; end if;
  if not public.is_company_member(source.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.documents(company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,payment_terms,payment_method,internal_notes,public_notes,discount_rate,total_cost,total_excl_tax,total_tax,total_incl_tax,source_document_id,opportunity_id,assigned_user_id,template_id,metadata,created_by)
  values(source.company_id,target_invoice_type,source.client_id,'draft',current_date,source.due_date,source.subject,source.client_reference,source.currency,source.language,source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,source.discount_rate,source.total_cost,source.total_excl_tax,source.total_tax,source.total_incl_tax,source.id,source.opportunity_id,source.assigned_user_id,source.template_id,source.metadata,auth.uid()) returning id into target_id;
  insert into public.document_lines(company_id,document_id,position,line_type,section_id,item_id,reference,name,description,quantity,unit,unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,total_excl_tax,total_tax,total_incl_tax,created_by)
  select company_id,target_id,position,line_type,section_id,item_id,reference,name,description,quantity,unit,unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,total_excl_tax,total_tax,total_incl_tax,auth.uid()
  from public.document_lines where document_id=source.id order by position;
  update public.documents set status='invoiced',updated_at=now() where id=source.id;
  return target_id;
end $$;

create or replace function public.record_document_payment(target_document_id uuid,payment_amount numeric,payment_method text default null,payment_reference text default null,payment_date timestamptz default now())
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; payment_id uuid; paid numeric; new_status text; remaining_payment numeric; schedule_row public.payment_schedules%rowtype; allocation numeric;
begin
  if payment_amount<=0 then raise exception 'invalid_payment_amount'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice') or doc.validated_at is null then raise exception 'invalid_invoice_state'; end if;
  if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select coalesce(sum(amount),0) into paid from public.payments where document_id=doc.id and status='confirmed';
  if paid+payment_amount>doc.total_incl_tax+0.01 then raise exception 'payment_exceeds_balance'; end if;
  insert into public.payments(company_id,document_id,amount,currency,paid_at,payment_method,reference,status,created_by)
  values(doc.company_id,doc.id,payment_amount,doc.currency,payment_date,payment_method,payment_reference,'confirmed',auth.uid()) returning id into payment_id;
  paid:=paid+payment_amount; new_status:=case when paid>=doc.total_incl_tax-0.01 then 'paid' else 'partially_paid' end;
  update public.documents set status=new_status,updated_at=now() where id=doc.id;
  remaining_payment:=payment_amount;
  for schedule_row in select * from public.payment_schedules where document_id=doc.id and status in('pending','partial') order by due_date,id for update loop
    exit when remaining_payment<=0;
    allocation:=least(remaining_payment,greatest(0,schedule_row.amount-schedule_row.paid_amount));
    update public.payment_schedules set paid_amount=paid_amount+allocation,status=case when paid_amount+allocation>=amount then 'paid' else 'partial' end where id=schedule_row.id;
    remaining_payment:=remaining_payment-allocation;
  end loop;
  return payment_id;
end $$;

create or replace function public.post_stock_movement(
  target_company_id uuid,target_item_id uuid,target_movement_type text,target_quantity numeric,target_unit text,
  source_warehouse_id uuid default null,destination_warehouse_id uuid default null,
  source_location_id uuid default null,destination_location_id uuid default null,
  movement_reason text default null,movement_comment text default null,target_unit_cost numeric default 0
)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare movement_id uuid;
begin
  if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if target_quantity<=0 then raise exception 'invalid_quantity'; end if;
  if target_movement_type not in('supplier_receipt','customer_delivery','customer_return','supplier_return','transfer','positive_adjustment','negative_adjustment','inventory','damage','loss','opening') then raise exception 'invalid_movement_type'; end if;
  insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,to_warehouse_id,to_location_id,reason,comment,unit_cost,status,created_by)
  values(target_company_id,target_item_id,target_movement_type,target_quantity,target_unit,source_warehouse_id,source_location_id,destination_warehouse_id,destination_location_id,movement_reason,movement_comment,coalesce(target_unit_cost,0),'validated',auth.uid()) returning id into movement_id;
  return movement_id;
end $$;

create or replace function public.apply_pipeline_automation()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare enabled jsonb; target_stage text;
begin
  if new.opportunity_id is null then return new; end if;
  select crm_automations into enabled from public.company_erp_settings where company_id=new.company_id;
  enabled:=coalesce(enabled,'{}'::jsonb);
  if tg_op='INSERT' then
    if new.document_type='quote' and coalesce((enabled->>'quote_created')::boolean,true) then target_stage:='quote_preparation';
    elsif new.document_type in('invoice','deposit_invoice') and coalesce((enabled->>'invoice_created')::boolean,true) then target_stage:='invoicing';
    end if;
  else
    if new.document_type='quote' and new.status='sent' and old.status is distinct from new.status and coalesce((enabled->>'quote_sent')::boolean,true) then target_stage:='quote_sent';
    elsif new.document_type='quote' and new.status='accepted' and old.status is distinct from new.status and coalesce((enabled->>'quote_accepted')::boolean,true) then target_stage:='won';
    elsif new.document_type='quote' and new.status='rejected' and old.status is distinct from new.status and coalesce((enabled->>'quote_rejected')::boolean,true) then target_stage:='lost';
    elsif new.document_type in('invoice','deposit_invoice') and new.status='paid' and old.status is distinct from new.status and coalesce((enabled->>'invoice_paid')::boolean,true) then target_stage:='collected';
    end if;
  end if;
  if target_stage is not null then
    update public.opportunities o set stage=target_stage,probability=coalesce((select probability from public.pipeline_stages where company_id=new.company_id and slug=target_stage),o.probability),closed_at=case when target_stage in('won','collected','lost') then now() else null end,updated_at=now() where o.id=new.opportunity_id and o.company_id=new.company_id;
  end if;
  return new;
end $$;
drop trigger if exists documents_pipeline_automation on public.documents;
create trigger documents_pipeline_automation after insert or update of status on public.documents for each row execute function public.apply_pipeline_automation();

grant execute on function public.convert_quote_to_invoice(uuid,text) to authenticated;
grant execute on function public.record_document_payment(uuid,numeric,text,text,timestamptz) to authenticated;
grant execute on function public.post_stock_movement(uuid,uuid,text,numeric,text,uuid,uuid,uuid,uuid,text,text,numeric) to authenticated;
revoke all on function public.seed_company_commercial_defaults() from public,anon,authenticated;
