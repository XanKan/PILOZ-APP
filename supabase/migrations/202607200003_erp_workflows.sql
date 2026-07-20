begin;

alter table public.documents drop constraint if exists documents_document_type_check;
alter table public.documents add constraint documents_document_type_check check(document_type in('quote','invoice','deposit_invoice','credit_note','sales_order','delivery_note','contract','purchase_order','reminder','statement'));

create table if not exists public.payments(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,
 document_id uuid not null references public.documents(id),amount numeric(15,2) not null check(amount>0),currency text not null default 'EUR',
 paid_at timestamptz not null default now(),payment_method text,reference text,status text not null default 'confirmed' check(status in('pending','confirmed','cancelled')),
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.item_prices(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,
 item_id uuid not null references public.catalog_items(id) on delete cascade,price_kind text not null default 'standard',client_id uuid references public.clients(id),
 min_quantity numeric(15,4) not null default 1,unit_price numeric(15,4) not null,currency text not null default 'EUR',valid_from date,valid_until date,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.stock_cost_history(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,item_id uuid not null references public.catalog_items(id),
 movement_id uuid references public.stock_movements(id),previous_cost numeric(15,4) not null,new_cost numeric(15,4) not null,quantity_received numeric(15,4),
 created_by uuid default auth.uid(),created_at timestamptz not null default now()
);
create table if not exists public.deliveries(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,number text,sales_order_id uuid references public.documents(id),
 client_id uuid references public.clients(id),warehouse_id uuid not null references public.warehouses(id),status text not null default 'draft',delivered_at timestamptz,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(company_id,number)
);
create table if not exists public.delivery_lines(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,delivery_id uuid not null references public.deliveries(id) on delete cascade,
 order_line_id uuid references public.document_lines(id),item_id uuid not null references public.catalog_items(id),location_id uuid references public.warehouse_locations(id),
 quantity numeric(15,4) not null check(quantity>0),created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.attachments(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,entity_type text not null,entity_id uuid not null,
 storage_path text not null,file_name text not null,mime_type text,size_bytes bigint,created_by uuid default auth.uid(),created_at timestamptz not null default now()
);
create table if not exists public.opportunities(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,client_id uuid references public.clients(id),name text not null,
 stage text not null default 'prospecting',amount numeric(15,2),probability numeric(5,2),owner_user_id uuid,next_action_at timestamptz,notes text,
 created_by uuid default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

do $policies$
declare t text;
begin
 foreach t in array array['payments','item_prices','stock_cost_history','deliveries','delivery_lines','attachments','opportunities'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',t||'_select',t);
  execute format('create policy %I on public.%I for insert to authenticated with check(public.is_company_member(company_id) and created_by=auth.uid())',t||'_insert',t);
  if t not in ('stock_cost_history','attachments') then
   execute format('create policy %I on public.%I for update to authenticated using(public.is_company_member(company_id)) with check(public.is_company_member(company_id))',t||'_update',t);
  end if;
  execute format('create policy %I on public.%I for delete to authenticated using(public.has_company_role(company_id,array[''owner'',''admin'']))',t||'_delete',t);
 end loop;
end $policies$;
drop policy if exists stock_cost_history_delete on public.stock_cost_history;

create or replace function public.recompute_document_totals(target_document_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare cid uuid;
begin
 select company_id into cid from public.documents where id=target_document_id;
 if not public.is_company_member(cid) then raise exception 'forbidden' using errcode='42501'; end if;
 update public.document_lines set
  total_excl_tax=round((quantity*unit_price*(1-discount_rate/100))::numeric,2),
  total_tax=round((quantity*unit_price*(1-discount_rate/100)*tax_rate/100)::numeric,2),
  total_incl_tax=round((quantity*unit_price*(1-discount_rate/100)*(1+tax_rate/100))::numeric,2)
 where document_id=target_document_id and line_type in('item','free_item','discount');
 update public.documents d set
  total_cost=coalesce(x.cost,0),total_excl_tax=coalesce(x.ht,0),total_tax=coalesce(x.tax,0),total_incl_tax=coalesce(x.ttc,0),updated_at=now()
 from(select sum(quantity*unit_cost_snapshot) cost,sum(total_excl_tax) ht,sum(total_tax) tax,sum(total_incl_tax) ttc from public.document_lines where document_id=target_document_id and not optional)x
 where d.id=target_document_id;
end $$;

create or replace function public.ensure_user_company(company_name text default 'Mon entreprise')
returns uuid language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare cid uuid;
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
 select company_id into cid from public.company_members where user_id=auth.uid() order by created_at limit 1;
 if cid is null then
  insert into public.companies(owner_user_id,name) values(auth.uid(),coalesce(nullif(trim(company_name),''),'Mon entreprise')) returning id into cid;
  insert into public.company_members(company_id,user_id,role) values(cid,auth.uid(),'owner');
 end if;
 insert into public.user_preferences(user_id,company_id,onboarding_completed) values(auth.uid(),cid,false)
 on conflict(user_id) do update set company_id=coalesce(public.user_preferences.company_id,excluded.company_id);
 insert into public.company_settings(company_id,legal_name,email) values(cid,null,(select email from auth.users where id=auth.uid())) on conflict(company_id) do nothing;
 insert into public.company_document_settings(company_id) values(cid) on conflict(company_id) do nothing;
 return cid;
end $$;

create or replace function public.validate_invoice(target_document_id uuid)
returns public.documents language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
 select * into doc from public.documents where id=target_document_id for update;
 if doc.document_type not in('invoice','deposit_invoice','credit_note') or doc.status<>'draft' then raise exception 'invalid_invoice_state'; end if;
 if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
 if doc.number is null then update public.documents set number=public.next_document_number(doc.company_id,doc.document_type),validated_at=now(),status='validated' where id=doc.id returning * into doc;
 else update public.documents set validated_at=now(),status='validated' where id=doc.id returning * into doc; end if;
 insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data) values(doc.company_id,'invoice.validated','document',doc.id,to_jsonb(doc));
 return doc;
end $$;

create or replace function public.confirm_sales_order(target_document_id uuid,target_warehouse_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; line record; available numeric;
begin
 select * into doc from public.documents where id=target_document_id for update;
 if doc.document_type<>'sales_order' or doc.status not in('draft','sent') then raise exception 'invalid_order_state'; end if;
 if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
 for line in select dl.* from public.document_lines dl join public.catalog_items i on i.id=dl.item_id where dl.document_id=doc.id and i.stock_managed loop
  perform pg_advisory_xact_lock(hashtextextended(line.item_id::text||':'||target_warehouse_id::text,0));
  select coalesce(sum(physical_quantity-reserved_quantity),0) into available from public.stock_levels where item_id=line.item_id and warehouse_id=target_warehouse_id;
  if available<line.quantity then raise exception 'insufficient_stock:%',line.item_id; end if;
  insert into public.stock_reservations(company_id,item_id,warehouse_id,quantity,source_type,source_id) values(doc.company_id,line.item_id,target_warehouse_id,line.quantity,'sales_order',doc.id);
 end loop;
 update public.documents set status='confirmed',number=coalesce(number,public.next_document_number(doc.company_id,'sales_order')) where id=doc.id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(doc.company_id,'sales_order.confirmed','document',doc.id);
end $$;

create or replace function public.cancel_sales_order(target_document_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
 select * into doc from public.documents where id=target_document_id for update;
 if doc.id is null or doc.document_type<>'sales_order' or doc.status not in('draft','sent','confirmed','partially_delivered') then raise exception 'invalid_order_state'; end if;
 if not public.is_company_member(doc.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
 update public.stock_reservations set status='released',updated_at=now() where source_type='sales_order' and source_id=target_document_id and status='active';
 update public.documents set status='cancelled' where id=target_document_id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(doc.company_id,'sales_order.cancelled','document',target_document_id);
end $$;

create or replace function public.validate_delivery(target_delivery_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare delivery public.deliveries%rowtype; line record; movement uuid; ordered_quantity numeric; delivered_before numeric; physical_available numeric;
begin
 select * into delivery from public.deliveries where id=target_delivery_id for update;
 if delivery.status<>'draft' then raise exception 'invalid_delivery_state'; end if;
 if not public.is_company_member(delivery.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
 perform 1 from public.documents where id=delivery.sales_order_id for update;
 if not exists(select 1 from public.documents d where d.id=delivery.sales_order_id and d.company_id=delivery.company_id and d.document_type='sales_order' and d.status in('confirmed','partially_delivered')) then raise exception 'invalid_sales_order_state'; end if;
 for line in select * from public.delivery_lines where delivery_id=delivery.id loop
  select dl.quantity into ordered_quantity from public.document_lines dl join public.catalog_items i on i.id=dl.item_id and i.stock_managed where dl.id=line.order_line_id and dl.document_id=delivery.sales_order_id and dl.item_id=line.item_id;
  if ordered_quantity is null then raise exception 'invalid_delivery_line:%',line.id; end if;
  select coalesce(sum(other_line.quantity),0) into delivered_before from public.delivery_lines other_line join public.deliveries other_delivery on other_delivery.id=other_line.delivery_id where other_line.order_line_id=line.order_line_id and other_delivery.sales_order_id=delivery.sales_order_id and other_delivery.status='validated' and other_delivery.id<>delivery.id;
  if line.quantity>ordered_quantity-delivered_before then raise exception 'delivery_quantity_exceeded:%',line.order_line_id; end if;
  select coalesce(sum(physical_quantity),0) into physical_available from public.stock_levels where item_id=line.item_id and warehouse_id=delivery.warehouse_id and (line.location_id is null or location_id=line.location_id);
  if physical_available<line.quantity then raise exception 'insufficient_physical_stock:%',line.item_id; end if;
  insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,source_type,source_id,unit_cost)
  select delivery.company_id,line.item_id,'customer_delivery',line.quantity,i.unit,delivery.warehouse_id,line.location_id,'delivery',delivery.id,i.cost_price from public.catalog_items i where i.id=line.item_id and i.stock_managed returning id into movement;
  update public.stock_reservations set quantity=greatest(quantity-line.quantity,0),status=case when quantity<=line.quantity then 'consumed' else status end,updated_at=now()
  where source_type='sales_order' and source_id=delivery.sales_order_id and item_id=line.item_id and status='active';
 end loop;
 update public.deliveries set status='validated',delivered_at=now() where id=delivery.id;
 update public.documents target set status=case when not exists(
  select 1 from public.document_lines order_line join public.catalog_items item on item.id=order_line.item_id and item.stock_managed
  where order_line.document_id=delivery.sales_order_id and coalesce((
   select sum(delivered_line.quantity) from public.delivery_lines delivered_line join public.deliveries delivered on delivered.id=delivered_line.delivery_id
   where delivered_line.order_line_id=order_line.id and (delivered.status='validated' or delivered.id=delivery.id)
  ),0)<order_line.quantity
 ) then 'delivered' else 'partially_delivered' end where target.id=delivery.sales_order_id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(delivery.company_id,'delivery.validated','delivery',delivery.id);
end $$;

create or replace function public.validate_goods_receipt(target_receipt_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare receipt public.goods_receipts%rowtype; line record; old_cost numeric; old_qty numeric; new_cost numeric; movement_id uuid; remaining_quantity numeric;
begin
 select * into receipt from public.goods_receipts where id=target_receipt_id for update;
 if receipt.status<>'draft' then raise exception 'invalid_receipt_state'; end if;
 if not exists(select 1 from public.company_members member where member.company_id=receipt.company_id and member.user_id=auth.uid() and (member.role in('owner','admin') or coalesce((member.permissions->>'view_purchase_prices')::boolean,false))) then raise exception 'forbidden' using errcode='42501'; end if;
 for line in select * from public.goods_receipt_lines where goods_receipt_id=receipt.id loop
  if line.purchase_order_line_id is not null then
   select quantity-received_quantity into remaining_quantity from public.purchase_order_lines
   where id=line.purchase_order_line_id and purchase_order_id=receipt.purchase_order_id and item_id=line.item_id for update;
   if remaining_quantity is null or line.quantity>remaining_quantity then raise exception 'receipt_quantity_exceeded:%',line.purchase_order_line_id; end if;
  end if;
  select cost_price into old_cost from public.catalog_items where id=line.item_id for update;
  select coalesce(sum(physical_quantity),0) into old_qty from public.stock_levels where item_id=line.item_id;
  new_cost:=case when old_qty+line.quantity=0 then line.unit_cost else ((old_qty*old_cost)+(line.quantity*line.unit_cost))/(old_qty+line.quantity) end;
  insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,to_warehouse_id,to_location_id,source_type,source_id,unit_cost)
  select receipt.company_id,line.item_id,'supplier_receipt',line.quantity,i.unit,receipt.warehouse_id,line.location_id,'goods_receipt',receipt.id,line.unit_cost from public.catalog_items i where i.id=line.item_id returning id into movement_id;
  update public.catalog_items set cost_price=new_cost where id=line.item_id;
  insert into public.stock_cost_history(company_id,item_id,movement_id,previous_cost,new_cost,quantity_received) values(receipt.company_id,line.item_id,movement_id,old_cost,new_cost,line.quantity);
  update public.purchase_order_lines set received_quantity=received_quantity+line.quantity where id=line.purchase_order_line_id;
 end loop;
 if receipt.purchase_order_id is not null then
  update public.purchase_orders po set status=case
   when not exists(select 1 from public.purchase_order_lines pol where pol.purchase_order_id=po.id and pol.received_quantity<pol.quantity) then 'received'
   else 'partially_received' end
  where po.id=receipt.purchase_order_id;
 end if;
 update public.goods_receipts set status='validated',received_at=now() where id=receipt.id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(receipt.company_id,'goods_receipt.validated','goods_receipt',receipt.id);
end $$;

create or replace function public.validate_inventory_count(target_count_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare inv public.inventory_counts%rowtype; line record; delta numeric;
begin
 select * into inv from public.inventory_counts where id=target_count_id for update;
 if inv.status<>'counted' then raise exception 'inventory_not_counted'; end if;
 if not exists(select 1 from public.company_members member where member.company_id=inv.company_id and member.user_id=auth.uid() and (member.role in('owner','admin') or coalesce((member.permissions->>'adjust_stock')::boolean,false))) then raise exception 'forbidden' using errcode='42501'; end if;
 for line in select * from public.inventory_count_lines where inventory_count_id=inv.id and counted_quantity is not null loop
  delta:=line.counted_quantity-line.theoretical_quantity;
  if delta>0 then insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,to_warehouse_id,to_location_id,source_type,source_id,reason) select inv.company_id,line.item_id,'inventory_adjustment_positive',delta,i.unit,inv.warehouse_id,line.location_id,'inventory',inv.id,'Écart inventaire' from public.catalog_items i where i.id=line.item_id;
  elsif delta<0 then insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,source_type,source_id,reason) select inv.company_id,line.item_id,'inventory_adjustment_negative',abs(delta),i.unit,inv.warehouse_id,line.location_id,'inventory',inv.id,'Écart inventaire' from public.catalog_items i where i.id=line.item_id; end if;
 end loop;
 update public.inventory_counts set status='validated',validated_at=now() where id=inv.id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id) values(inv.company_id,'inventory.validated','inventory_count',inv.id);
end $$;

create or replace function public.reverse_stock_movement(target_movement_id uuid, reversal_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare original public.stock_movements%rowtype; new_id uuid;
begin
 select * into original from public.stock_movements where id=target_movement_id for update;
 if original.status<>'validated' or original.reversal_of is not null then raise exception 'movement_not_reversible'; end if;
 if not exists(select 1 from public.company_members member where member.company_id=original.company_id and member.user_id=auth.uid() and (member.role in('owner','admin') or coalesce((member.permissions->>'adjust_stock')::boolean,false))) then raise exception 'forbidden' using errcode='42501'; end if;
 insert into public.stock_movements(company_id,item_id,movement_type,quantity,unit,from_warehouse_id,from_location_id,to_warehouse_id,to_location_id,source_type,source_id,reason,unit_cost,comment,reversal_of,status)
 values(original.company_id,original.item_id,'reversal',original.quantity,original.unit,original.to_warehouse_id,original.to_location_id,original.from_warehouse_id,original.from_location_id,'stock_movement',original.id,coalesce(reversal_reason,'Correction'),original.unit_cost,original.comment,original.id,'validated') returning id into new_id;
 update public.stock_movements set status='reversed',updated_at=now() where id=original.id;
 insert into public.activity_logs(company_id,action,entity_type,entity_id,new_data) values(original.company_id,'stock_movement.reversed','stock_movement',original.id,jsonb_build_object('reversal_id',new_id,'reason',reversal_reason));
 return new_id;
end $$;

revoke all on function public.ensure_user_company(text),public.recompute_document_totals(uuid),public.validate_invoice(uuid),public.confirm_sales_order(uuid,uuid),public.cancel_sales_order(uuid),public.validate_delivery(uuid),public.validate_goods_receipt(uuid),public.validate_inventory_count(uuid),public.reverse_stock_movement(uuid,text) from public;
grant execute on function public.ensure_user_company(text),public.recompute_document_totals(uuid),public.validate_invoice(uuid),public.confirm_sales_order(uuid,uuid),public.cancel_sales_order(uuid),public.validate_delivery(uuid),public.validate_goods_receipt(uuid),public.validate_inventory_count(uuid),public.reverse_stock_movement(uuid,text) to authenticated;

drop policy if exists document_lines_delete on public.document_lines;
create policy document_lines_delete_member on public.document_lines for delete to authenticated using(public.is_company_member(company_id));

commit;
