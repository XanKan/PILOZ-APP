begin;

-- Les remises et commentaires sont des mecanismes de document. Les packs
-- restent des conteneurs commerciaux historiques dont les composants sont
-- ventilés individuellement. Seuls ces quatre types portent un compte de vente.
create or replace function public.sales_account_type_label(target_item_type text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case target_item_type
    when 'product' then 'Article'
    when 'service' then 'Service'
    when 'subscription' then 'Abonnement'
    when 'fee' then 'Frais'
    else coalesce(target_item_type,'Type inconnu')
  end
$$;

create or replace function public.resolve_sales_account_code(
  target_company_id uuid,target_item_type text,target_effective_on date default current_date
) returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare resolved_code text;
begin
  if target_item_type not in('product','service','subscription','fee') then
    raise exception 'accounting_sales_type_invalid:%',coalesce(target_item_type,'null') using errcode='22023';
  end if;
  select mapping.account_code into resolved_code
  from public.accounting_account_mappings mapping
  where mapping.company_id=target_company_id
    and mapping.direction='sale'
    and mapping.scope_type='item_type'
    and mapping.scope_value=target_item_type
    and mapping.active
    and mapping.effective_from<=coalesce(target_effective_on,current_date)
  order by mapping.effective_from desc,mapping.updated_at desc,mapping.id desc
  limit 1;
  if resolved_code is null then
    raise exception 'accounting_sales_account_missing:%',public.sales_account_type_label(target_item_type)
      using errcode='23514';
  end if;
  return resolved_code;
end
$$;

create or replace function public.validate_sales_account_type_mappings(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare missing_types jsonb;
begin
  if auth.uid() is not null and not public.is_company_member(target_company_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('key',required.item_type,'label',public.sales_account_type_label(required.item_type)) order by required.position),'[]'::jsonb)
  into missing_types
  from (values('product',1),('service',2),('subscription',3),('fee',4)) required(item_type,position)
  where not exists(
    select 1 from public.accounting_account_mappings mapping
    where mapping.company_id=target_company_id and mapping.direction='sale'
      and mapping.scope_type='item_type' and mapping.scope_value=required.item_type
      and mapping.active and mapping.effective_from<=current_date
      and nullif(trim(mapping.account_code),'') is not null
  );
  return jsonb_build_object('ok',jsonb_array_length(missing_types)=0,'missing',missing_types);
end
$$;

create or replace function public.assert_sales_account_type_mappings(target_company_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare report jsonb;labels text;
begin
  report:=public.validate_sales_account_type_mappings(target_company_id);
  if not coalesce((report->>'ok')::boolean,false) then
    select string_agg(value->>'label',', ') into labels from jsonb_array_elements(report->'missing');
    raise exception 'accounting_sales_accounts_missing:%',coalesce(labels,'Article, Service, Abonnement, Frais') using errcode='23514';
  end if;
end
$$;

-- Valeurs par defaut des installations existantes. Les comptes reellement
-- personnalises sont conserves ; seuls les anciens generiques 701/701000 sont
-- remplaces par les nouveaux comptes metier.
do $seed_sales_accounts$
declare company_row record;configured record;existing_id uuid;existing_code text;year_start date:=make_date(extract(year from current_date)::integer,1,1);
begin
  for company_row in select id from public.companies loop
    delete from public.accounting_account_mappings
    where company_id=company_row.id and direction='sale' and scope_type='item_type'
      and scope_value in('package','discount','comment');
    delete from public.item_accounting_profiles
    where company_id=company_row.id and item_id is null and category_id is null
      and item_type in('package','discount','comment');

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
      elsif existing_code in('701','701000') then
        update public.accounting_account_mappings set account_code=configured.default_account,updated_at=now()
        where id=existing_id;
      end if;
    end loop;
    update public.accounting_settings set default_sales_account='706000',updated_at=now()
    where company_id=company_row.id and default_sales_account in('701','701000');
  end loop;
end
$seed_sales_accounts$;

-- Configuration des nouvelles entreprises. Le trigger historique pointe vers
-- cette fonction remplacee et recoit donc automatiquement les quatre comptes.
create or replace function public.bootstrap_new_company_accounting()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare configured record;vat_row record;payment_kind text;year_start date:=make_date(extract(year from current_date)::integer,1,1);
begin
  perform public._bootstrap_company_accounting(new.id,current_date);
  update public.accounting_settings set default_sales_account='706000',updated_at=now() where company_id=new.id;
  for configured in select * from (values
    ('product','707000'),('service','706000'),('subscription','706000'),('fee','708000')
  ) values_to_seed(item_type,default_account) loop
    insert into public.accounting_account_mappings(company_id,direction,scope_type,scope_value,account_code,effective_from,active)
    values(new.id,'sale','item_type',configured.item_type,configured.default_account,year_start,true)
    on conflict(company_id,direction,scope_type,scope_value,effective_from)
    do update set account_code=excluded.account_code,active=true,updated_at=now();
  end loop;
  delete from public.accounting_account_mappings
  where company_id=new.id and direction='sale' and scope_type='item_type'
    and scope_value in('package','discount','comment');
  delete from public.item_accounting_profiles
  where company_id=new.id and item_id is null and category_id is null
    and item_type in('package','discount','comment');
  for vat_row in select * from (values
    (0::numeric,'3'),(2.1::numeric,'004'),(5.5::numeric,'001'),(8.5::numeric,'005'),(10::numeric,'003'),(20::numeric,'002')
  ) configured(rate,extension) loop
    insert into public.accounting_vat_mappings(company_id,tax_rate,sale_account_extension,purchase_account_extension,effective_from)
    values(new.id,vat_row.rate,vat_row.extension,vat_row.extension,year_start)
    on conflict(company_id,tax_rate,effective_from) do update set
      sale_account_extension=coalesce(public.accounting_vat_mappings.sale_account_extension,excluded.sale_account_extension),
      purchase_account_extension=coalesce(public.accounting_vat_mappings.purchase_account_extension,excluded.purchase_account_extension);
  end loop;
  insert into public.accounting_financial_accounts(company_id,name,account_code,account_type,active)
  select new.id,'BANQUE PRINCIPALE','512100','bank',true
  where not exists(select 1 from public.accounting_financial_accounts where company_id=new.id and account_type='bank');
  for payment_kind in select unnest(array['bank_transfer','direct_debit','card','cheque','check','cash','paypal','other']) loop
    insert into public.accounting_payment_method_mappings(company_id,payment_method,financial_account_code,active)
    values(new.id,payment_kind,'512100',true) on conflict(company_id,payment_method) do nothing;
  end loop;
  return new;
end
$$;

-- Les anciens enregistrements restent lisibles, mais aucune nouvelle fiche ne
-- peut etre creee avec un pseudo-type comptable ou commercial obsolete.
create or replace function public.enforce_catalog_item_business_type()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then
    if new.item_type not in('product','service','subscription','fee') then
      raise exception 'catalog_item_type_not_selectable:%',new.item_type using errcode='23514';
    end if;
  elsif new.item_type is distinct from old.item_type
        and new.item_type not in('product','service','subscription','fee') then
    raise exception 'catalog_item_type_not_selectable:%',new.item_type using errcode='23514';
  end if;
  return new;
end
$$;
drop trigger if exists catalog_items_enforce_business_type on public.catalog_items;
create trigger catalog_items_enforce_business_type
before insert or update of item_type on public.catalog_items
for each row execute function public.enforce_catalog_item_business_type();

-- Le moteur produit une ligne client, une ligne de TVA par taux et une seule
-- ligne de produit par compte. Les remises de ligne sont deja comprises dans
-- total_excl_tax ; les remises explicites/globales diminuent les comptes au
-- prorata. Les packs sont eclates selon leurs composants.
create or replace function public._generate_document_accounting_entry(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype;settings public.accounting_settings%rowtype;fiscal public.accounting_fiscal_years%rowtype;journal public.accounting_journals%rowtype;
  entry_id uuid;entry_num text;party_label text;auxiliary text;collective text;direction text;sign integer:=1;line_no integer:=0;
  line_row record;component_row record;account_row record;adjustment_row record;tax_row record;
  resolved_account_code text;vat_account text;item_type_value text;sum_debit numeric:=0;sum_credit numeric:=0;gross numeric;net numeric;tax numeric;
  source_net numeric:=0;net_adjustment numeric:=0;discount_adjustment numeric:=0;deposit_adjustment numeric:=0;explicit_discount numeric:=0;
  source_tax numeric:=0;posted_tax numeric:=0;allocated_tax numeric:=0;allocation numeric:=0;allocated_components numeric:=0;
  weight_total numeric:=0;base_total numeric:=0;remaining_discount numeric:=0;component_count integer:=0;component_index integer:=0;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public._piloz_accounting_document_is_final(doc.id)
     or doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice') then return null;end if;
  select id into entry_id from public.accounting_entries
  where company_id=doc.company_id and source_type='document' and source_id=doc.id and event_kind='original';
  if entry_id is not null then return entry_id;end if;
  perform public._bootstrap_company_accounting(doc.company_id,doc.issue_date);
  select * into settings from public.accounting_settings where company_id=doc.company_id;
  select * into fiscal from public.accounting_fiscal_years
    where company_id=doc.company_id and doc.issue_date between starts_on and ends_on limit 1;
  direction:=case when doc.document_type='purchase_invoice' then 'purchase' else 'sale' end;
  select * into journal from public.accounting_journals
    where company_id=doc.company_id and journal_type=case when direction='sale' then 'sales' else 'purchases' end and active
    order by display_order,id limit 1;
  if fiscal.id is null or journal.id is null then raise exception 'accounting_configuration_incomplete';end if;
  if doc.document_type='credit_note' then sign:=-1;end if;

  if direction='sale' then
    select coalesce(nullif(trim(coalesce(client.legal_name,concat_ws(' ',client.first_name,client.last_name))),''),'Client')
      into party_label from public.clients client where client.id=doc.client_id;
    auxiliary:=public.ensure_accounting_third_party_identifier(doc.company_id,'client',doc.client_id,party_label);
    select coalesce(profile.collective_account,settings.customer_collective_account),
      case when profile.assignment_mode='manual' then left(regexp_replace(upper(coalesce(profile.auxiliary_account,'')),'[^A-Z0-9]','','g'),10) else auxiliary end
      into collective,auxiliary from public.client_accounting_profiles profile where profile.client_id=doc.client_id;
    if coalesce(settings.customer_account_mode,'individualized')='individualized' then
      collective:=public.ensure_client_individual_account(doc.company_id,doc.client_id,party_label);auxiliary:=null;
    else
      collective:=case when coalesce(collective,settings.customer_collective_account)='411000' then '411' else coalesce(collective,settings.customer_collective_account) end;
      auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,'client',doc.client_id,party_label));
    end if;
  else
    select coalesce(nullif(trim(supplier.legal_name),''),'Fournisseur') into party_label from public.suppliers supplier where supplier.id=doc.supplier_id;
    auxiliary:=public.ensure_accounting_third_party_identifier(doc.company_id,'supplier',doc.supplier_id,party_label);
    select coalesce(profile.collective_account,settings.supplier_collective_account),
      case when profile.assignment_mode='manual' then left(regexp_replace(upper(coalesce(profile.auxiliary_account,'')),'[^A-Z0-9]','','g'),10) else auxiliary end
      into collective,auxiliary from public.supplier_accounting_profiles profile where profile.supplier_id=doc.supplier_id;
    collective:=coalesce(collective,settings.supplier_collective_account);
    auxiliary:=coalesce(auxiliary,public.ensure_accounting_third_party_identifier(doc.company_id,'supplier',doc.supplier_id,party_label));
  end if;

  entry_num:=public.next_accounting_entry_number(doc.company_id,doc.issue_date);
  insert into public.accounting_entries(company_id,fiscal_year_id,journal_id,entry_number,entry_date,piece_reference,piece_date,label,currency,source_type,source_id,event_kind,document_id,status,created_by)
  values(doc.company_id,fiscal.id,journal.id,entry_num,doc.issue_date,coalesce(doc.number,doc.id::text),doc.issue_date,
    coalesce(doc.subject,case when direction='sale' then 'Vente ' else 'Achat ' end||coalesce(doc.number,'')),doc.currency,
    'document',doc.id,'original',doc.id,'posted',coalesce(doc.finalized_by,doc.created_by)) returning id into entry_id;
  gross:=round(abs(doc.total_incl_tax),2);net:=round(abs(doc.total_excl_tax),2);tax:=round(abs(doc.total_tax),2);
  line_no:=line_no+1;
  insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,auxiliary_code,auxiliary_label,third_party_id,line_label,debit,credit,currency,created_by)
  values(doc.company_id,entry_id,line_no,collective,case when direction='sale' then party_label else 'Fournisseur - '||party_label end,
    auxiliary,case when auxiliary is null then null else party_label end,coalesce(doc.client_id,doc.supplier_id),coalesce(doc.number,'Document'),
    case when (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then gross else 0 end,
    case when (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then gross else 0 end,
    doc.currency,coalesce(doc.finalized_by,doc.created_by));
  if (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then sum_debit:=sum_debit+gross;else sum_credit:=sum_credit+gross;end if;

  if direction='sale' then
    create temporary table if not exists piloz_sales_account_totals(
      account_code text primary key,amount numeric not null default 0
    ) on commit drop;
    truncate table piloz_sales_account_totals;

    for line_row in
      select line.id,line.item_id,line.line_type,line.line_metadata,line.tax_rate,
        round(abs(coalesce(line.total_excl_tax,0)),2) amount,
        coalesce(item.item_type,nullif(line.line_metadata->>'accounting_item_type',''),'service') item_type
      from public.document_lines line
      left join public.catalog_items item on item.id=line.item_id and item.company_id=line.company_id
      where line.document_id=doc.id and not line.optional
        and line.line_type in('item','free_item','variant','discount')
        and abs(coalesce(line.total_excl_tax,0))>0
      order by line.position,line.id
    loop
      item_type_value:=line_row.item_type;
      if line_row.line_type='discount' or item_type_value='discount' then
        explicit_discount:=explicit_discount+line_row.amount;continue;
      end if;
      if item_type_value='comment' then continue;end if;
      if item_type_value='package' then
        select count(*),coalesce(sum(component.quantity*greatest(abs(coalesce(item.sale_price,0)),1)),0)
        into component_count,weight_total
        from public.item_bundle_components component
        join public.catalog_items item on item.id=component.component_item_id and item.company_id=doc.company_id
        where component.bundle_item_id=line_row.item_id and component.company_id=doc.company_id;
        if component_count=0 then raise exception 'accounting_pack_components_missing:%',coalesce(line_row.item_id::text,'pack') using errcode='23514';end if;
        component_index:=0;allocated_components:=0;
        for component_row in
          select component.component_item_id,item.item_type,
            component.quantity*greatest(abs(coalesce(item.sale_price,0)),1) weight
          from public.item_bundle_components component
          join public.catalog_items item on item.id=component.component_item_id and item.company_id=doc.company_id
          where component.bundle_item_id=line_row.item_id and component.company_id=doc.company_id
          order by component.position,component.id
        loop
          component_index:=component_index+1;
          if component_row.item_type not in('product','service','subscription','fee') then
            raise exception 'accounting_pack_component_type_invalid:%',component_row.item_type using errcode='23514';
          end if;
          resolved_account_code:=public.resolve_sales_account_code(doc.company_id,component_row.item_type,doc.issue_date);
          allocation:=case when component_index=component_count then round(line_row.amount-allocated_components,2)
            else round(line_row.amount*component_row.weight/nullif(weight_total,0),2) end;
          allocated_components:=allocated_components+allocation;
          insert into piloz_sales_account_totals(account_code,amount) values(resolved_account_code,allocation)
          on conflict(account_code) do update set amount=piloz_sales_account_totals.amount+excluded.amount;
        end loop;
      else
        resolved_account_code:=public.resolve_sales_account_code(doc.company_id,item_type_value,doc.issue_date);
        insert into piloz_sales_account_totals(account_code,amount) values(resolved_account_code,line_row.amount)
        on conflict(account_code) do update set amount=piloz_sales_account_totals.amount+excluded.amount;
      end if;
      source_net:=source_net+line_row.amount;
    end loop;

    net_adjustment:=round(source_net-net,2);
    if net_adjustment < -0.01 then raise exception 'accounting_sales_net_inconsistent:%',net_adjustment using errcode='23514';end if;
    if net_adjustment>0.01 then
      discount_adjustment:=least(net_adjustment,round(explicit_discount+source_net*coalesce(doc.discount_rate,0)/100,2));
    end if;
    deposit_adjustment:=round(net_adjustment-discount_adjustment,2);

    if discount_adjustment>0.01 then
      select coalesce(sum(amount),0) into base_total from piloz_sales_account_totals where amount>0;
      if base_total<=0 then raise exception 'accounting_discount_allocation_impossible' using errcode='23514';end if;
      remaining_discount:=discount_adjustment;
      for account_row in
        select account_code,amount,row_number() over(order by account_code) row_number,count(*) over() row_count
        from piloz_sales_account_totals where amount>0 order by account_code
      loop
        allocation:=case when account_row.row_number=account_row.row_count then remaining_discount
          else round(discount_adjustment*account_row.amount/base_total,2) end;
        update piloz_sales_account_totals set amount=round(amount-allocation,2) where account_code=account_row.account_code;
        remaining_discount:=round(remaining_discount-allocation,2);
      end loop;
    end if;

    for account_row in select account_code,round(amount,2) amount from piloz_sales_account_totals where abs(amount)>0.01 order by account_code loop
      line_no:=line_no+1;
      insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,created_by)
      values(doc.company_id,entry_id,line_no,account_row.account_code,'Ventes',coalesce(doc.number,'Document'),
        case when sign=-1 then account_row.amount else 0 end,case when sign=1 then account_row.amount else 0 end,
        doc.currency,coalesce(doc.finalized_by,doc.created_by));
      if sign=-1 then sum_debit:=sum_debit+account_row.amount;else sum_credit:=sum_credit+account_row.amount;end if;
    end loop;
  else
    for line_row in
      select line.id,line.item_id,line.tax_rate,round(abs(line.total_excl_tax),2) amount,item.category_id,item.item_type
      from public.document_lines line left join public.catalog_items item on item.id=line.item_id
      where line.document_id=doc.id and line.line_type in('item','free_item') and not line.optional and abs(line.total_excl_tax)>0
      order by line.position,line.id
    loop
      select profile.purchase_account_code into resolved_account_code from public.item_accounting_profiles profile
      where profile.company_id=doc.company_id and profile.is_active
        and (profile.item_id=line_row.item_id or profile.category_id=line_row.category_id or profile.item_type=line_row.item_type)
      order by (profile.item_id is not null) desc,(profile.category_id is not null) desc,(profile.item_type is not null) desc,profile.priority desc limit 1;
      resolved_account_code:=coalesce(resolved_account_code,settings.default_purchase_account);
      line_no:=line_no+1;
      insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,source_line_id,tax_rate,created_by)
      values(doc.company_id,entry_id,line_no,resolved_account_code,'Achats',coalesce(doc.number,'Document'),line_row.amount,0,doc.currency,line_row.id,line_row.tax_rate,coalesce(doc.finalized_by,doc.created_by));
      sum_debit:=sum_debit+line_row.amount;source_net:=source_net+line_row.amount;
    end loop;
    net_adjustment:=round(source_net-net,2);
    if net_adjustment>0.01 and coalesce(doc.discount_rate,0)>0 then discount_adjustment:=least(net_adjustment,round(source_net*doc.discount_rate/100,2));end if;
    deposit_adjustment:=round(net_adjustment-discount_adjustment,2);
    for adjustment_row in select * from (values
      (discount_adjustment,coalesce((select complementary.account_code from public.accounting_complementary_accounts complementary
        where complementary.company_id=doc.company_id and complementary.setting_key='discount_received' and complementary.active
        order by complementary.updated_at desc,complementary.id desc limit 1),'765'),'Escomptes obtenus'),
      (deposit_adjustment,settings.default_purchase_account,'Ajustement achats')
    ) adjustments(amount,adjustment_account,adjustment_label) where abs(amount)>0.01 loop
      line_no:=line_no+1;
      insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,created_by)
      values(doc.company_id,entry_id,line_no,adjustment_row.adjustment_account,adjustment_row.adjustment_label,coalesce(doc.number,'Document'),
        0,adjustment_row.amount,doc.currency,coalesce(doc.finalized_by,doc.created_by));
      sum_credit:=sum_credit+adjustment_row.amount;
    end loop;
  end if;

  if direction='sale' and abs(deposit_adjustment)>0.01 then
    line_no:=line_no+1;
    resolved_account_code:=case when settings.deposit_method='direct' then settings.default_sales_account else settings.deposit_account end;
    insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,created_by)
    values(doc.company_id,entry_id,line_no,resolved_account_code,'Acomptes deja factures',coalesce(doc.number,'Document'),
      case when sign=1 then abs(deposit_adjustment) else 0 end,case when sign=-1 then abs(deposit_adjustment) else 0 end,
      doc.currency,coalesce(doc.finalized_by,doc.created_by));
    if sign=1 then sum_debit:=sum_debit+abs(deposit_adjustment);else sum_credit:=sum_credit+abs(deposit_adjustment);end if;
  end if;

  if tax>0 then
    select coalesce(sum(rate_tax),0) into source_tax from (
      select round(sum(abs(coalesce(line.total_tax,0))),2) rate_tax
      from public.document_lines line
      where line.document_id=doc.id and line.line_type in('item','free_item','variant','discount')
        and not line.optional and abs(coalesce(line.total_tax,0))>0 group by line.tax_rate
    ) taxes;
    if source_tax<=0 then raise exception 'accounting_vat_breakdown_missing';end if;
    for tax_row in
      select line.tax_rate,round(sum(abs(coalesce(line.total_tax,0))),2) source_amount,
        row_number() over(order by line.tax_rate) rate_number,count(*) over() rate_count
      from public.document_lines line
      where line.document_id=doc.id and line.line_type in('item','free_item','variant','discount')
        and not line.optional and abs(coalesce(line.total_tax,0))>0
      group by line.tax_rate order by line.tax_rate
    loop
      allocated_tax:=case when tax_row.rate_number=tax_row.rate_count then round(tax-posted_tax,2)
        else round(tax*tax_row.source_amount/source_tax,2) end;
      if abs(allocated_tax)<=0.01 then continue;end if;
      select case when direction='sale' then mapping.sales_account else mapping.purchase_account end into vat_account
      from public.accounting_vat_mappings mapping
      where mapping.company_id=doc.company_id and mapping.active and mapping.tax_rate=tax_row.tax_rate
        and mapping.effective_from<=doc.issue_date
      order by mapping.effective_from desc,mapping.id desc limit 1;
      if vat_account is null then raise exception 'accounting_vat_account_missing:%',tax_row.tax_rate;end if;
      line_no:=line_no+1;
      insert into public.accounting_entry_lines(company_id,entry_id,line_number,account_code,account_label,line_label,debit,credit,currency,tax_rate,created_by)
      values(doc.company_id,entry_id,line_no,vat_account,case when direction='sale' then 'TVA collectee' else 'TVA deductible' end,coalesce(doc.number,'Document'),
        case when (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then allocated_tax else 0 end,
        case when (direction='sale' and sign=1) or (direction='purchase' and sign=-1) then allocated_tax else 0 end,
        doc.currency,tax_row.tax_rate,coalesce(doc.finalized_by,doc.created_by));
      posted_tax:=posted_tax+allocated_tax;
      if (direction='purchase' and sign=1) or (direction='sale' and sign=-1) then sum_debit:=sum_debit+allocated_tax;else sum_credit:=sum_credit+allocated_tax;end if;
    end loop;
  end if;
  if abs(sum_debit-sum_credit)>0.01 then raise exception 'accounting_entry_unbalanced:%',round(sum_debit-sum_credit,2);end if;
  return entry_id;
end
$$;

-- Validation serveur avant toute previsualisation, donc aussi avant la
-- generation du fichier final par un adaptateur Sage/EBP/Cegid/Pennylane.
do $patch_sales_export_validation$
declare source_definition text;patched_definition text;period_check text:='if target_ends_on<target_starts_on then raise exception ''invalid_period'';end if;';
begin
  source_definition:=pg_get_functiondef('public.preview_accounting_export(uuid,text,date,date,text,boolean)'::regprocedure);
  if position('perform public.assert_sales_account_type_mappings(target_company_id);' in source_definition)=0 then
    patched_definition:=replace(source_definition,period_check,
      'if target_journal_type=''sales'' then perform public.assert_sales_account_type_mappings(target_company_id);end if;'||chr(10)||'  '||period_check);
    if patched_definition=source_definition then raise exception 'sales_export_validation_patch_not_applied';end if;
    execute patched_definition;
  end if;
end
$patch_sales_export_validation$;

revoke all on function public.sales_account_type_label(text) from public,anon;
revoke all on function public.resolve_sales_account_code(uuid,text,date) from public,anon,authenticated;
revoke all on function public.assert_sales_account_type_mappings(uuid) from public,anon,authenticated;
revoke all on function public.validate_sales_account_type_mappings(uuid) from public,anon;
grant execute on function public.validate_sales_account_type_mappings(uuid) to authenticated;

comment on function public.resolve_sales_account_code(uuid,text,date) is
  'Resout le compte de vente des quatre types comptables autorises : Article, Service, Abonnement, Frais.';
comment on function public.validate_sales_account_type_mappings(uuid) is
  'Controle bloquant des quatre comptes de vente requis avant export.';

alter table public.company_fiscal_configurations alter column schema_version set default '202607270090';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.45',schema_version='202607270090',updated_at=now()
where application_version is distinct from '0.9.0-compliance.45'
   or schema_version is distinct from '202607270090';

commit;
