begin;

-- Cockpit de pilotage PILOZ.
-- Migration strictement additive : les documents, paiements, clients, stocks et
-- activites existants restent les seules sources de verite.

create table if not exists public.dashboard_preferences(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  layout_version integer not null default 1 check(layout_version between 1 and 1000),
  visible_blocks jsonb not null default '[]'::jsonb check(jsonb_typeof(visible_blocks)='array'),
  block_order jsonb not null default '[]'::jsonb check(jsonb_typeof(block_order)='array'),
  block_sizes jsonb not null default '{}'::jsonb check(jsonb_typeof(block_sizes)='object'),
  selected_metrics jsonb not null default '[]'::jsonb check(jsonb_typeof(selected_metrics)='array'),
  period_config jsonb not null default '{"preset":"current_month","comparison":"previous"}'::jsonb
    check(jsonb_typeof(period_config)='object'),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,user_id)
);

alter table public.dashboard_preferences enable row level security;
drop policy if exists dashboard_preferences_select_self on public.dashboard_preferences;
drop policy if exists dashboard_preferences_insert_self on public.dashboard_preferences;
drop policy if exists dashboard_preferences_update_self on public.dashboard_preferences;
drop policy if exists dashboard_preferences_delete_self on public.dashboard_preferences;
create policy dashboard_preferences_select_self on public.dashboard_preferences for select to authenticated
  using(user_id=auth.uid() and public.is_company_member(company_id));
create policy dashboard_preferences_insert_self on public.dashboard_preferences for insert to authenticated
  with check(user_id=auth.uid() and created_by=auth.uid() and public.is_company_member(company_id));
create policy dashboard_preferences_update_self on public.dashboard_preferences for update to authenticated
  using(user_id=auth.uid() and public.is_company_member(company_id))
  with check(user_id=auth.uid() and public.is_company_member(company_id));
create policy dashboard_preferences_delete_self on public.dashboard_preferences for delete to authenticated
  using(user_id=auth.uid() and public.is_company_member(company_id));

drop trigger if exists dashboard_preferences_set_updated_at on public.dashboard_preferences;
create trigger dashboard_preferences_set_updated_at before update on public.dashboard_preferences
  for each row execute function public.set_current_timestamp_updated_at();

insert into public.dashboard_preferences(
  company_id,user_id,visible_blocks,block_order,block_sizes,created_by
)
select widget.company_id,widget.user_id,
  coalesce(jsonb_agg(widget.widget_key order by widget.position) filter(where widget.widget_key<>'__empty__'),'[]'::jsonb),
  coalesce(jsonb_agg(widget.widget_key order by widget.position) filter(where widget.widget_key<>'__empty__'),'[]'::jsonb),
  coalesce(jsonb_object_agg(widget.widget_key,case when widget.width>1 then 'wide' else 'normal' end)
    filter(where widget.widget_key<>'__empty__'),'{}'::jsonb),
  widget.user_id
from public.dashboard_widgets widget
group by widget.company_id,widget.user_id
on conflict(company_id,user_id) do nothing;

create index if not exists dashboard_documents_period_idx
  on public.documents(company_id,document_type,issue_date,status);
create index if not exists dashboard_documents_due_idx
  on public.documents(company_id,due_date,status)
  where document_type in('invoice','deposit_invoice','balance_invoice');
create index if not exists dashboard_quotes_validity_idx
  on public.documents(company_id,validity_date,status) where document_type='quote';
create index if not exists dashboard_payments_period_idx
  on public.payments(company_id,paid_at,status,document_id);
create index if not exists dashboard_lines_document_item_idx
  on public.document_lines(company_id,document_id,item_id,position);
create index if not exists dashboard_activities_assignee_idx
  on public.activities(company_id,assigned_user_id,scheduled_at,completed_at);
create index if not exists dashboard_clients_created_idx
  on public.clients(company_id,created_at);
create index if not exists dashboard_opportunities_stage_idx
  on public.opportunities(company_id,stage,assigned_user_id);

create or replace function public._dashboard_request_context()
returns table(
  company_id uuid,user_id uuid,member_role text,member_permissions jsonb,currency text,
  company_timezone text,data_scope text,can_revenue boolean,can_margin boolean,
  can_stock boolean,can_purchase_prices boolean,can_purchases boolean,can_write boolean,
  can_sales_documents boolean,can_customers boolean,can_payments boolean,
  can_activities boolean,can_catalog boolean,can_reminders boolean
)
language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id,member.user_id,member.role,coalesce(member.permissions,'{}'::jsonb),
    coalesce(settings.currency,'EUR'),coalesce(automation.timezone,'Europe/Paris'),
    case when member.role='sales' then 'personal' else 'company' end,
    public.has_company_permission(member.company_id,'application_read'),
    public.has_company_permission(member.company_id,'view_margins'),
    public.has_feature(member.company_id,'inventory') and (
      public.has_company_permission(member.company_id,'view_stock')
      or public.has_company_permission(member.company_id,'adjust_stock')
    ),
    public.has_company_permission(member.company_id,'view_purchase_prices'),
    (public.has_company_permission(member.company_id,'view_purchase_prices')
      or public.has_company_permission(member.company_id,'manage_purchase_orders')),
    (public.has_company_permission(member.company_id,'sales_document_write')
      or public.has_company_permission(member.company_id,'manage_customer')
      or public.has_company_permission(member.company_id,'manage_opportunity'))
      and coalesce(company.platform_status,'active')='active'
      and coalesce(member.platform_status,'active')='active',
    public.has_company_permission(member.company_id,'sales_document_write'),
    public.has_company_permission(member.company_id,'manage_customer'),
    (public.has_company_permission(member.company_id,'record_payment')
      or public.has_company_permission(member.company_id,'record_multi_invoice_payment')),
    (public.has_company_permission(member.company_id,'manage_opportunity')
      or public.has_company_permission(member.company_id,'manage_customer')),
    public.can_manage_catalog(member.company_id,'catalog_create'),
    (public.has_company_permission(member.company_id,'manage_reminder')
      or public.has_company_permission(member.company_id,'resend_invoice'))
  from public.company_members member
  join public.companies company on company.id=member.company_id
  left join public.user_preferences preference on preference.user_id=member.user_id
  left join public.company_settings settings on settings.company_id=member.company_id
  left join public.fiscal_automation_policies automation on automation.company_id=member.company_id
  where member.user_id=auth.uid()
    and coalesce(member.platform_status,'active')='active'
    and coalesce(company.platform_status,'active') not in('deletion_pending','anonymized')
  order by (preference.company_id=member.company_id) desc,member.created_at
  limit 1
$$;

create or replace function public._dashboard_period_bounds(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns table(
  range_start date,range_end date,comparison_start date,comparison_end date,
  granularity text,timezone text
)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  context_row record;
  local_today date;
  selected_key text:=lower(coalesce(nullif(trim(period_key),''),'current_month'));
  selected_comparison text:=lower(coalesce(nullif(trim(comparison_mode),''),'previous'));
  start_value date;
  end_value date;
  duration_days integer;
begin
  select * into context_row from public._dashboard_request_context();
  if context_row.company_id is null then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  if not context_row.can_revenue then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  local_today:=(clock_timestamp() at time zone context_row.company_timezone)::date;
  case selected_key
    when 'today' then start_value:=local_today; end_value:=local_today+1;
    when 'current_week' then start_value:=date_trunc('week',local_today::timestamp)::date; end_value:=start_value+7;
    when 'last_7_days' then start_value:=local_today-6; end_value:=local_today+1;
    when 'last_30_days' then start_value:=local_today-29; end_value:=local_today+1;
    when 'previous_month' then start_value:=(date_trunc('month',local_today::timestamp)-interval '1 month')::date; end_value:=date_trunc('month',local_today::timestamp)::date;
    when 'current_quarter' then start_value:=date_trunc('quarter',local_today::timestamp)::date; end_value:=(date_trunc('quarter',local_today::timestamp)+interval '3 months')::date;
    when 'quarter' then start_value:=date_trunc('quarter',local_today::timestamp)::date; end_value:=(date_trunc('quarter',local_today::timestamp)+interval '3 months')::date;
    when 'current_year' then start_value:=date_trunc('year',local_today::timestamp)::date; end_value:=(date_trunc('year',local_today::timestamp)+interval '1 year')::date;
    when 'year' then start_value:=date_trunc('year',local_today::timestamp)::date; end_value:=(date_trunc('year',local_today::timestamp)+interval '1 year')::date;
    when 'previous_year' then start_value:=(date_trunc('year',local_today::timestamp)-interval '1 year')::date; end_value:=date_trunc('year',local_today::timestamp)::date;
    when 'custom' then
      if custom_start is null or custom_end is null or custom_end<custom_start or custom_end-custom_start>3660 then
        raise exception 'invalid_dashboard_period';
      end if;
      start_value:=custom_start; end_value:=custom_end+1;
    else start_value:=date_trunc('month',local_today::timestamp)::date; end_value:=(date_trunc('month',local_today::timestamp)+interval '1 month')::date;
  end case;
  duration_days:=greatest(1,end_value-start_value);
  range_start:=start_value;
  range_end:=end_value;
  if selected_comparison='year' then
    comparison_start:=(start_value-interval '1 year')::date;
    comparison_end:=(end_value-interval '1 year')::date;
  elsif selected_comparison='none' then
    comparison_start:=null; comparison_end:=null;
  else
    comparison_start:=start_value-duration_days;
    comparison_end:=start_value;
  end if;
  granularity:=case when duration_days<=45 then 'day' when duration_days<=180 then 'week'
    when duration_days<=730 then 'month' else 'year' end;
  timezone:=context_row.company_timezone;
  return next;
end
$$;

create or replace function public.get_dashboard_preferences()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; preference_row public.dashboard_preferences%rowtype;
begin
  select * into context_row from public._dashboard_request_context();
  if context_row.company_id is null then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  select * into preference_row from public.dashboard_preferences preference
    where preference.company_id=context_row.company_id and preference.user_id=context_row.user_id;
  return jsonb_build_object(
    'layout_version',coalesce(preference_row.layout_version,1),
    'visible_blocks',coalesce(preference_row.visible_blocks,'[]'::jsonb),
    'block_order',coalesce(preference_row.block_order,'[]'::jsonb),
    'block_sizes',coalesce(preference_row.block_sizes,'{}'::jsonb),
    'selected_metrics',coalesce(preference_row.selected_metrics,'[]'::jsonb),
    'period_config',coalesce(preference_row.period_config,'{"preset":"current_month","comparison":"previous"}'::jsonb),
    'role',context_row.member_role
  );
end
$$;

create or replace function public.save_dashboard_preferences(
  target_layout_version integer,target_visible_blocks jsonb,target_block_order jsonb,
  target_block_sizes jsonb,target_selected_metrics jsonb,target_period_config jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record; allowed_blocks constant text[]:=array[
  'receivables','commercial','recent_documents','customers','catalog','stock','agenda',
  'purchases','notifications','forecast'
]; allowed_metrics constant text[]:=array[
  'revenue_ht','collected','outstanding','gross_margin','quote_count','accepted_quote_count',
  'conversion_rate','average_invoice_ht','overdue_count','new_clients','purchases_ht','stock_value','gross_result'
]; invalid_key text;
begin
  select * into context_row from public._dashboard_request_context();
  if context_row.company_id is null then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(target_visible_blocks,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_block_order,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_block_sizes,'{}'::jsonb))<>'object'
    or jsonb_typeof(coalesce(target_selected_metrics,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_period_config,'{}'::jsonb))<>'object' then
    raise exception 'invalid_dashboard_preferences';
  end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_visible_blocks,'[]'::jsonb)) item(value)
    where not(value=any(allowed_blocks)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_block:%',invalid_key; end if;
  if jsonb_array_length(coalesce(target_selected_metrics,'[]'::jsonb))>4 then raise exception 'too_many_dashboard_metrics'; end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_selected_metrics,'[]'::jsonb)) item(value)
    where not(value=any(allowed_metrics)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_metric:%',invalid_key; end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_block_order,'[]'::jsonb)) item(value)
    where not(value=any(allowed_blocks)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_block:%',invalid_key; end if;
  insert into public.dashboard_preferences(
    company_id,user_id,layout_version,visible_blocks,block_order,block_sizes,
    selected_metrics,period_config,created_by
  ) values(
    context_row.company_id,context_row.user_id,greatest(1,coalesce(target_layout_version,1)),
    coalesce(target_visible_blocks,'[]'::jsonb),coalesce(target_block_order,'[]'::jsonb),
    coalesce(target_block_sizes,'{}'::jsonb),coalesce(target_selected_metrics,'[]'::jsonb),
    coalesce(target_period_config,'{}'::jsonb),context_row.user_id
  ) on conflict(company_id,user_id) do update set
    layout_version=excluded.layout_version,visible_blocks=excluded.visible_blocks,
    block_order=excluded.block_order,block_sizes=excluded.block_sizes,
    selected_metrics=excluded.selected_metrics,period_config=excluded.period_config,updated_at=now();
  return public.get_dashboard_preferences();
end
$$;

create or replace function public.get_dashboard_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with scoped_documents as(
    select document.* from public.documents document
    where document.company_id=context_row.company_id
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  ), finalized_sales as(
    select document.*,
      case when document.document_type='credit_note' then -1 else 1 end sign
    from scoped_documents document
    where document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
  ), current_sales as(
    select * from finalized_sales where issue_date>=bounds_row.range_start and issue_date<bounds_row.range_end
  ), previous_sales as(
    select * from finalized_sales where bounds_row.comparison_start is not null
      and issue_date>=bounds_row.comparison_start and issue_date<bounds_row.comparison_end
  ), current_payments as(
    select payment.* from public.payments payment join scoped_documents document on document.id=payment.document_id
    where payment.company_id=context_row.company_id and payment.status='confirmed'
      and (payment.paid_at at time zone bounds_row.timezone)::date>=bounds_row.range_start
      and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
  ), previous_payments as(
    select payment.* from public.payments payment join scoped_documents document on document.id=payment.document_id
    where bounds_row.comparison_start is not null and payment.company_id=context_row.company_id and payment.status='confirmed'
      and (payment.paid_at at time zone bounds_row.timezone)::date>=bounds_row.comparison_start
      and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.comparison_end
  ), payments_to_date as(
    select payment.document_id,coalesce(sum(payment.amount),0) amount
    from public.payments payment join scoped_documents document on document.id=payment.document_id
    where payment.company_id=context_row.company_id and payment.status='confirmed'
      and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
    group by payment.document_id
  ), credits_to_date as(
    select credit.source_document_id,coalesce(sum(credit.total_incl_tax),0) amount
    from finalized_sales credit where credit.document_type='credit_note'
      and credit.source_document_id is not null and credit.issue_date<bounds_row.range_end
    group by credit.source_document_id
  ), open_invoices as(
    select invoice.*,greatest(0,invoice.total_incl_tax-coalesce(payment.amount,0)-coalesce(credit.amount,0)) remaining
    from finalized_sales invoice
    left join payments_to_date payment on payment.document_id=invoice.id
    left join credits_to_date credit on credit.source_document_id=invoice.id
    where invoice.document_type in('invoice','deposit_invoice','balance_invoice')
      and invoice.issue_date<bounds_row.range_end
  ), open_rows as(select * from open_invoices where remaining>0.005),
  current_quotes as(
    select * from scoped_documents quote where quote.document_type='quote'
      and quote.issue_date>=bounds_row.range_start and quote.issue_date<bounds_row.range_end
      and quote.status not in('cancelled','archived')
  ), decided_quotes as(
    select * from current_quotes where status in('accepted','invoiced','rejected')
  ), positive_payments as(
    select payment.*,document.issue_date from current_payments payment
    join scoped_documents document on document.id=payment.document_id
    where payment.amount>0 and coalesce(payment.entry_type,'payment') in('payment','overpayment')
  ), values as(
    select
      coalesce((select sum(sign*total_excl_tax) from current_sales),0) revenue_ht,
      coalesce((select sum(sign*total_incl_tax) from current_sales),0) revenue_ttc,
      coalesce((select sum(sign*total_cost) from current_sales),0) cost,
      coalesce((select sum(amount) from current_payments),0) collected,
      coalesce((select sum(sign*total_excl_tax) from previous_sales),0) previous_revenue_ht,
      coalesce((select sum(amount) from previous_payments),0) previous_collected,
      coalesce((select sum(remaining) from open_rows),0) outstanding,
      coalesce((select sum(remaining) from open_rows where due_date<bounds_row.range_end-1),0) overdue_amount,
      (select count(*) from open_rows) outstanding_count,
      (select count(*) from open_rows where due_date<bounds_row.range_end-1) overdue_count,
      (select count(*) from current_sales where document_type<>'credit_note') invoice_count,
      (select count(*) from current_quotes) quote_count,
      (select count(*) from current_quotes where status in('accepted','invoiced')) accepted_quote_count,
      (select count(*) from decided_quotes) decided_quote_count,
      coalesce((select avg(greatest(0,(payment.paid_at at time zone bounds_row.timezone)::date-payment.issue_date)) from positive_payments payment),0) average_payment_days
  )
  select jsonb_build_object(
    'period',jsonb_build_object('start',bounds_row.range_start,'end',bounds_row.range_end-1,
      'comparison_start',bounds_row.comparison_start,'comparison_end',bounds_row.comparison_end-1,
      'granularity',bounds_row.granularity,'timezone',bounds_row.timezone),
    'scope',context_row.data_scope,'currency',context_row.currency,
    'permissions',jsonb_build_object('revenue',context_row.can_revenue,'margin',context_row.can_margin,
      'stock',context_row.can_stock,'purchase_prices',context_row.can_purchase_prices,
      'purchases',context_row.can_purchases,'write',context_row.can_write,
      'sales_documents',context_row.can_sales_documents,'customers',context_row.can_customers,
      'payments',context_row.can_payments,'activities',context_row.can_activities,
      'catalog_write',context_row.can_catalog,'reminders',context_row.can_reminders),
    'revenue_ht',round(values.revenue_ht,2),'revenue_ttc',round(values.revenue_ttc,2),
    'collected',round(values.collected,2),'outstanding',round(values.outstanding,2),
    'gross_margin',case when context_row.can_margin then round(values.revenue_ht-values.cost,2) else null end,
    'margin_rate',case when context_row.can_margin and values.revenue_ht<>0 then round((values.revenue_ht-values.cost)/abs(values.revenue_ht)*100,2) else null end,
    'previous_revenue_ht',round(values.previous_revenue_ht,2),'previous_collected',round(values.previous_collected,2),
    'revenue_change_percent',case when values.previous_revenue_ht<>0 then round((values.revenue_ht-values.previous_revenue_ht)/abs(values.previous_revenue_ht)*100,2) else null end,
    'collected_change_percent',case when values.previous_collected<>0 then round((values.collected-values.previous_collected)/abs(values.previous_collected)*100,2) else null end,
    'outstanding_count',values.outstanding_count,'overdue_count',values.overdue_count,
    'overdue_amount',round(values.overdue_amount,2),'invoice_count',values.invoice_count,
    'average_invoice_ht',case when values.invoice_count>0 then round(values.revenue_ht/values.invoice_count,2) else null end,
    'quote_count',values.quote_count,'accepted_quote_count',values.accepted_quote_count,
    'conversion_rate',case when values.decided_quote_count>0 then round(values.accepted_quote_count::numeric/values.decided_quote_count*100,2) else null end,
    'average_payment_days',round(values.average_payment_days,1),
    'definitions',jsonb_build_object(
      'revenue_ht','Factures finalisees HT moins avoirs finalises sur la periode.',
      'collected','Paiements confirmes, nets des corrections, remboursements, rejets et chargebacks.',
      'outstanding','Factures finalisees ouvertes, nettes des paiements et avoirs lies a la date de fin.',
      'gross_margin','CA HT net moins couts d achat memorises sur les documents.',
      'conversion_rate','Devis acceptes ou factures divises par les devis acceptes, factures ou refuses.'
    )
  ) into result from values;
  return result;
end
$$;

create or replace function public.get_revenue_timeseries(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with buckets as(
    select row_number() over(order by value)::integer position,value::date bucket
    from generate_series(
      date_trunc(bounds_row.granularity,bounds_row.range_start::timestamp),
      date_trunc(bounds_row.granularity,(bounds_row.range_end-1)::timestamp),
      case bounds_row.granularity when 'day' then interval '1 day' when 'week' then interval '1 week'
        when 'year' then interval '1 year' else interval '1 month' end
    ) value
  ), comparison_buckets as(
    select row_number() over(order by value)::integer position,value::date bucket
    from generate_series(
      date_trunc(bounds_row.granularity,bounds_row.comparison_start::timestamp),
      date_trunc(bounds_row.granularity,(bounds_row.comparison_end-1)::timestamp),
      case bounds_row.granularity when 'day' then interval '1 day' when 'week' then interval '1 week'
        when 'year' then interval '1 year' else interval '1 month' end
    ) value where bounds_row.comparison_start is not null
  ), scoped_documents as(
    select document.* from public.documents document
    where document.company_id=context_row.company_id
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  ), sales as(
    select date_trunc(bounds_row.granularity,document.issue_date::timestamp)::date bucket,
      sum((case when document.document_type='credit_note' then -1 else 1 end)*document.total_excl_tax) invoiced,
      sum((case when document.document_type='credit_note' then -1 else 1 end)*(document.total_excl_tax-document.total_cost)) margin,
      count(*) filter(where document.document_type<>'credit_note') invoice_count,
      coalesce(sum(document.total_excl_tax) filter(where document.document_type<>'credit_note'),0) gross_invoiced,
      coalesce(sum(document.total_excl_tax) filter(where document.document_type='credit_note'),0) credits
    from scoped_documents document where document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
      and document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end
    group by 1
  ), comparison_sales as(
    select date_trunc(bounds_row.granularity,document.issue_date::timestamp)::date bucket,
      sum((case when document.document_type='credit_note' then -1 else 1 end)*document.total_excl_tax) invoiced
    from scoped_documents document where bounds_row.comparison_start is not null
      and document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
      and document.issue_date>=bounds_row.comparison_start and document.issue_date<bounds_row.comparison_end
    group by 1
  ), payment_values as(
    select date_trunc(bounds_row.granularity,payment.paid_at at time zone bounds_row.timezone)::date bucket,
      sum(payment.amount) collected,
      coalesce(sum(payment.amount) filter(where payment.amount>0),0) positive_collected,
      coalesce(sum(-payment.amount) filter(where payment.amount<0),0) corrections
    from public.payments payment join scoped_documents document on document.id=payment.document_id
    where payment.company_id=context_row.company_id and payment.status='confirmed'
      and (payment.paid_at at time zone bounds_row.timezone)::date>=bounds_row.range_start
      and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
    group by 1
  ), points as(
    select bucket.position,bucket.bucket,comparison.bucket comparison_bucket,
      coalesce(sale.invoiced,0) invoiced,coalesce(payment.collected,0) collected,
      case when context_row.can_margin then coalesce(sale.margin,0) else null end margin,
      coalesce(sale.invoice_count,0) invoice_count,coalesce(sale.gross_invoiced,0) gross_invoiced,
      coalesce(sale.credits,0) credits,coalesce(payment.positive_collected,0) positive_collected,
      coalesce(payment.corrections,0) corrections,
      coalesce(comparison_sale.invoiced,0) comparison
    from buckets bucket
    left join sales sale on sale.bucket=bucket.bucket
    left join payment_values payment on payment.bucket=bucket.bucket
    left join comparison_buckets comparison on comparison.position=bucket.position
    left join comparison_sales comparison_sale on comparison_sale.bucket=comparison.bucket
    order by bucket.position
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',bucket,'comparison_date',comparison_bucket,'invoiced',round(invoiced,2),
    'collected',round(collected,2),'margin',case when margin is null then null else round(margin,2) end,
    'invoice_count',invoice_count,'gross_invoiced',round(gross_invoiced,2),'credits',round(credits,2),
    'positive_collected',round(positive_collected,2),'corrections',round(corrections,2),
    'comparison',round(comparison,2)
  ) order by position),'[]'::jsonb) into result from points;
  return result;
end
$$;

create or replace function public.get_receivables_dashboard_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with scoped_invoices as(
    select document.* from public.documents document where document.company_id=context_row.company_id
      and document.document_type in('invoice','deposit_invoice','balance_invoice')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
      and document.issue_date<bounds_row.range_end
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  ), paid as(
    select payment.document_id,sum(payment.amount) amount from public.payments payment
    join scoped_invoices invoice on invoice.id=payment.document_id
    where payment.status='confirmed' and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
    group by payment.document_id
  ), credited as(
    select credit.source_document_id,sum(credit.total_incl_tax) amount from public.documents credit
    where credit.company_id=context_row.company_id and credit.document_type='credit_note'
      and credit.source_document_id is not null and credit.status not in('draft','cancelled','archived')
      and credit.issue_date<bounds_row.range_end group by credit.source_document_id
  ), open_rows as(
    select invoice.*,greatest(0,invoice.total_incl_tax-coalesce(paid.amount,0)-coalesce(credited.amount,0)) remaining,
      greatest(0,(bounds_row.range_end-1)-coalesce(invoice.due_date,bounds_row.range_end-1)) age
    from scoped_invoices invoice left join paid on paid.document_id=invoice.id
    left join credited on credited.source_document_id=invoice.id
  ), active as(select * from open_rows where remaining>0.005)
  select jsonb_build_object(
    'total',round(coalesce(sum(remaining),0),2),'count',count(*),
    'average_delay',round(coalesce(avg(age) filter(where age>0),0),1),
    'oldest_delay',coalesce(max(age) filter(where age>0),0),
    'buckets',jsonb_build_array(
      jsonb_build_object('key','not_due','label','A echoir','count',count(*) filter(where due_date>=bounds_row.range_end-1),'amount',round(coalesce(sum(remaining) filter(where due_date>=bounds_row.range_end-1),0),2)),
      jsonb_build_object('key','days_1_15','label','1 a 15 jours','count',count(*) filter(where age between 1 and 15),'amount',round(coalesce(sum(remaining) filter(where age between 1 and 15),0),2)),
      jsonb_build_object('key','days_16_30','label','16 a 30 jours','count',count(*) filter(where age between 16 and 30),'amount',round(coalesce(sum(remaining) filter(where age between 16 and 30),0),2)),
      jsonb_build_object('key','days_31_60','label','31 a 60 jours','count',count(*) filter(where age between 31 and 60),'amount',round(coalesce(sum(remaining) filter(where age between 31 and 60),0),2)),
      jsonb_build_object('key','days_60_plus','label','Plus de 60 jours','count',count(*) filter(where age>60),'amount',round(coalesce(sum(remaining) filter(where age>60),0),2))
    ),
    'oldest',coalesce((select jsonb_agg(jsonb_build_object('id',id,'number',number,'client_id',client_id,'due_date',due_date,'remaining',round(remaining,2),'days',age) order by age desc) from (select * from active where age>0 order by age desc,remaining desc limit 6) rows),'[]'::jsonb)
  ) into result from active;
  return result;
end
$$;

create or replace function public.get_cash_collection_forecast(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb; as_of_date date;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  as_of_date:=least(bounds_row.range_end-1,(clock_timestamp() at time zone bounds_row.timezone)::date);
  with invoice_balances as(
    select document.id,document.due_date,document.total_incl_tax-
      coalesce((select sum(payment.amount) from public.payments payment where payment.document_id=document.id and payment.status='confirmed' and (payment.paid_at at time zone bounds_row.timezone)::date<=as_of_date),0)-
      coalesce((select sum(credit.total_incl_tax) from public.documents credit where credit.source_document_id=document.id and credit.document_type='credit_note' and credit.status not in('draft','cancelled','archived') and credit.issue_date<=as_of_date),0) remaining
    from public.documents document where document.company_id=context_row.company_id
      and document.document_type in('invoice','deposit_invoice','balance_invoice')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
      and document.issue_date<=as_of_date
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  ), due_rows as(
    select coalesce(schedule.due_date,balance.due_date,as_of_date) due_date,
      case when schedule.id is null then balance.remaining else least(balance.remaining,greatest(0,schedule.amount-schedule.paid_amount)) end amount,
      case when schedule.id is null then 'invoice' else 'schedule' end source
    from invoice_balances balance left join public.payment_schedules schedule
      on schedule.document_id=balance.id and schedule.status in('pending','partial')
    where balance.remaining>0.005
  ), buckets as(
    select case
      when due_date<as_of_date then 'overdue'
      when due_date<=as_of_date+7 then 'days_7'
      when due_date<=as_of_date+30 then 'days_30'
      when due_date<=as_of_date+60 then 'days_60'
      else 'later' end key,sum(amount) amount,count(*) count
    from due_rows group by 1
  )
  select jsonb_build_object('as_of',as_of_date,'horizon_end',as_of_date+90,
    'source_label','Echeances contractuelles et plans de reglement ouverts',
    'total',round(coalesce((select sum(amount) from due_rows where due_date<=as_of_date+90),0),2),
    'highlights',jsonb_build_object(
      'this_week',round(coalesce((select sum(amount) from due_rows where due_date>=as_of_date
        and due_date<(date_trunc('week',as_of_date::timestamp)+interval '1 week')::date),0),2),
      'next_week',round(coalesce((select sum(amount) from due_rows
        where due_date>=(date_trunc('week',as_of_date::timestamp)+interval '1 week')::date
          and due_date<(date_trunc('week',as_of_date::timestamp)+interval '2 week')::date),0),2),
      'this_month',round(coalesce((select sum(amount) from due_rows where due_date>=as_of_date
        and due_date<(date_trunc('month',as_of_date::timestamp)+interval '1 month')::date),0),2),
      'next_month',round(coalesce((select sum(amount) from due_rows
        where due_date>=(date_trunc('month',as_of_date::timestamp)+interval '1 month')::date
          and due_date<(date_trunc('month',as_of_date::timestamp)+interval '2 month')::date),0),2)
    ),
    'buckets',coalesce((select jsonb_agg(jsonb_build_object('key',key,'amount',round(amount,2),'count',count)
      order by case key when 'overdue' then 1 when 'days_7' then 2 when 'days_30' then 3 when 'days_60' then 4 else 5 end) from buckets),'[]'::jsonb)
  ) into result;
  return result;
end
$$;

create or replace function public.get_dashboard_priority_actions(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb; as_of_date date;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  as_of_date:=least(bounds_row.range_end-1,(clock_timestamp() at time zone bounds_row.timezone)::date);
  with payment_totals as(
    select document_id,sum(amount) amount from public.payments where company_id=context_row.company_id and status='confirmed' group by document_id
  ), actions as(
    select 100 priority,'overdue_invoice' kind,document.id entity_id,
      coalesce(document.number,'Facture') title,
      'Echeance depassee de '||greatest(1,as_of_date-document.due_date)||' jour(s)' detail,
      greatest(0,document.total_incl_tax-coalesce(payment.amount,0)) impact,document.due_date action_date,'danger' tone
    from public.documents document left join payment_totals payment on payment.document_id=document.id
    where document.company_id=context_row.company_id and document.document_type in('invoice','deposit_invoice','balance_invoice')
      and document.status not in('draft','cancelled','archived','paid') and document.due_date<as_of_date
      and greatest(0,document.total_incl_tax-coalesce(payment.amount,0))>0.005
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
    union all
    select 70,'expiring_quote',quote.id,coalesce(quote.number,'Devis'),
      'Expire le '||to_char(quote.validity_date,'DD/MM/YYYY'),quote.total_incl_tax,quote.validity_date,'warning'
    from public.documents quote where quote.company_id=context_row.company_id and quote.document_type='quote'
      and quote.status in('draft','to_send','sent','viewed','pending')
      and quote.validity_date between as_of_date and as_of_date+7
      and (context_row.data_scope='company' or quote.assigned_user_id=context_row.user_id
        or (quote.assigned_user_id is null and quote.created_by=context_row.user_id))
    union all
    select 80,'overdue_activity',activity.id,activity.subject,
      'Activite commerciale en retard',0,coalesce(activity.scheduled_at::date,as_of_date),'danger'
    from public.activities activity where activity.company_id=context_row.company_id
      and activity.completed_at is null and coalesce(activity.metadata->>'status','todo') not in('completed','cancelled')
      and coalesce(nullif(activity.metadata->>'due_at','')::timestamptz,activity.scheduled_at)<clock_timestamp()
      and (context_row.data_scope='company' or activity.assigned_user_id=context_row.user_id
        or activity.created_by=context_row.user_id)
    union all
    select 65,'accepted_quote',quote.id,coalesce(quote.number,'Devis accepté'),
      'Devis accepté à convertir en facture',quote.total_incl_tax,coalesce(quote.accepted_at::date,quote.updated_at::date),'success'
    from public.documents quote where quote.company_id=context_row.company_id and quote.document_type='quote'
      and quote.status='accepted' and not exists(select 1 from public.documents invoice
        where invoice.company_id=context_row.company_id and invoice.source_document_id=quote.id
          and invoice.document_type in('invoice','deposit_invoice','balance_invoice')
          and invoice.status not in('cancelled','archived'))
      and (context_row.data_scope='company' or quote.assigned_user_id=context_row.user_id
        or (quote.assigned_user_id is null and quote.created_by=context_row.user_id))
    union all
    select 50,'incomplete_draft',document.id,coalesce(document.number,'Facture brouillon'),
      'Brouillon incomplet à vérifier',document.total_incl_tax,document.updated_at::date,'warning'
    from public.documents document where document.company_id=context_row.company_id
      and document.document_type in('invoice','deposit_invoice','balance_invoice') and document.status='draft'
      and (document.client_id is null or not exists(select 1 from public.document_lines line where line.document_id=document.id))
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
    union all
    select 60,'low_stock',item.id,item.name,
      'Stock disponible sous le seuil',0,as_of_date,'warning'
    from public.catalog_items item
    where context_row.can_stock and item.company_id=context_row.company_id and item.stock_managed and item.active
      and coalesce((select sum(level.physical_quantity-level.reserved_quantity) from public.stock_levels level where level.item_id=item.id),0)
        <coalesce(item.reorder_point,item.minimum_stock,0)
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind',kind,'id',entity_id,'title',title,'detail',detail,
    'impact',round(impact,2),'date',action_date,'tone',tone,
    'assigned_user_id',case when kind='overdue_activity' then (select activity.assigned_user_id from public.activities activity where activity.id=entity_id)
      when kind='low_stock' then null else (select document.assigned_user_id from public.documents document where document.id=entity_id) end,
    'can_write',case when kind='overdue_invoice' then context_row.can_reminders
      when kind='overdue_activity' then context_row.can_activities
      when kind in('expiring_quote','accepted_quote','incomplete_draft') then context_row.can_sales_documents
      when kind='low_stock' then context_row.can_purchases else false end)
    order by priority desc,impact desc,action_date) filter(where row_number<=12),'[]'::jsonb)
  into result from (select actions.*,row_number() over(order by priority desc,impact desc,action_date) row_number from actions) ranked;
  return result;
end
$$;

create or replace function public.get_sales_funnel_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with stages as(
    select case
      when document.status in('draft','to_send') then 'draft'
      when document.status in('sent','viewed') then 'sent'
      when document.status='pending' then 'pending'
      when document.status='accepted' then 'accepted'
      when document.status='rejected' then 'rejected'
      when document.status='invoiced' then 'invoiced'
      when document.status='expired' then 'expired' else 'other' end key,
      count(*) count,coalesce(sum(document.total_excl_tax),0) amount
    from public.documents document where document.company_id=context_row.company_id and document.document_type='quote'
      and document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end
      and document.status not in('cancelled','archived')
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
    group by 1
  ), totals as(select coalesce(sum(count),0) quote_count,coalesce(sum(amount),0) amount from stages),
  decisions as(select coalesce(sum(count) filter(where key in('accepted','invoiced','rejected')),0) decided,
    coalesce(sum(count) filter(where key in('accepted','invoiced')),0) accepted from stages)
  select jsonb_build_object('quote_count',totals.quote_count,'amount',round(totals.amount,2),
    'conversion_rate',case when decisions.decided>0 then round(decisions.accepted::numeric/decisions.decided*100,2) else null end,
    'pending_amount',round(coalesce((select sum(amount) from stages where key in('sent','pending')),0),2),
    'accepted_amount',round(coalesce((select sum(amount) from stages where key in('accepted','invoiced')),0),2),
    'expiring_soon',(select count(*) from public.documents document where document.company_id=context_row.company_id
      and document.document_type='quote' and document.status in('sent','viewed','pending')
      and document.validity_date between bounds_row.range_end-1 and bounds_row.range_end+6
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))),
    'stages',coalesce((select jsonb_agg(jsonb_build_object('key',key,'count',count,'amount',round(amount,2))
      order by case key when 'draft' then 1 when 'sent' then 2 when 'pending' then 3 when 'accepted' then 4 when 'rejected' then 5 when 'invoiced' then 6 when 'expired' then 7 else 8 end) from stages),'[]'::jsonb)
  ) into result from totals cross join decisions;
  return result;
end
$$;

create or replace function public.get_customer_performance_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with scoped_documents as(
    select document.* from public.documents document where document.company_id=context_row.company_id
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  ), scoped_clients as(
    select client.* from public.clients client where client.company_id=context_row.company_id
      and (context_row.data_scope='company'
        or exists(select 1 from scoped_documents document where document.client_id=client.id)
        or exists(select 1 from public.activities activity where activity.company_id=context_row.company_id
          and activity.client_id=client.id and (activity.assigned_user_id=context_row.user_id or activity.created_by=context_row.user_id)))
  ), finalized_sales as(
    select document.* from scoped_documents document
    where document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
  ), sales as(
    select document.client_id,
      sum((case when document.document_type='credit_note' then -1 else 1 end)*document.total_excl_tax) revenue,
      sum((case when document.document_type='credit_note' then -1 else 1 end)*(document.total_excl_tax-document.total_cost)) margin
    from finalized_sales document
    where document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end
    group by document.client_id
  ), collected as(
    select document.client_id,sum(payment.amount) collected
    from public.payments payment join scoped_documents document on document.id=payment.document_id
    where payment.company_id=context_row.company_id and payment.status='confirmed'
      and (payment.paid_at at time zone bounds_row.timezone)::date>=bounds_row.range_start
      and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
    group by document.client_id
  ), paid_to_date as(
    select payment.document_id,sum(payment.amount) amount from public.payments payment
    join finalized_sales document on document.id=payment.document_id
    where payment.status='confirmed' and (payment.paid_at at time zone bounds_row.timezone)::date<bounds_row.range_end
    group by payment.document_id
  ), credited_to_date as(
    select credit.source_document_id,sum(credit.total_incl_tax) amount from finalized_sales credit
    where credit.document_type='credit_note' and credit.source_document_id is not null
      and credit.issue_date<bounds_row.range_end group by credit.source_document_id
  ), open_by_client as(
    select invoice.client_id,sum(greatest(0,invoice.total_incl_tax-coalesce(paid.amount,0)-coalesce(credit.amount,0))) outstanding,
      sum(greatest(0,invoice.total_incl_tax-coalesce(paid.amount,0)-coalesce(credit.amount,0)))
        filter(where invoice.due_date<bounds_row.range_end-1) overdue
    from finalized_sales invoice left join paid_to_date paid on paid.document_id=invoice.id
    left join credited_to_date credit on credit.source_document_id=invoice.id
    where invoice.document_type in('invoice','deposit_invoice','balance_invoice')
      and invoice.issue_date<bounds_row.range_end group by invoice.client_id
  ), values as(
    select client.id,coalesce(client.legal_name,client.trade_name,concat_ws(' ',client.first_name,client.last_name),'Client') name,
      coalesce(sales.revenue,0) revenue,coalesce(sales.margin,0) margin,
      coalesce(collected.collected,0) collected,coalesce(open_by_client.outstanding,0) outstanding,
      coalesce(open_by_client.overdue,0) overdue
    from scoped_clients client left join sales on sales.client_id=client.id
    left join collected on collected.client_id=client.id left join open_by_client on open_by_client.client_id=client.id
    where coalesce(sales.revenue,0)<>0 or coalesce(collected.collected,0)<>0 or coalesce(open_by_client.outstanding,0)<>0
  ), ranked as(
    select values.*,
      row_number() over(order by revenue desc,id) revenue_rank,
      row_number() over(order by margin desc,id) margin_rank,
      row_number() over(order by outstanding desc,id) outstanding_rank,
      row_number() over(order by overdue desc,id) overdue_rank,
      sum(revenue) over() total_revenue
    from values
  ), top_rows as(select * from ranked where least(revenue_rank,margin_rank,outstanding_rank,overdue_rank)<=5)
  select jsonb_build_object(
    'new_clients',(select count(*) from scoped_clients client
      where (client.created_at at time zone bounds_row.timezone)::date>=bounds_row.range_start
      and (client.created_at at time zone bounds_row.timezone)::date<bounds_row.range_end),
    'active_clients',(select count(*) from sales where revenue<>0),
    'without_recent_activity',(select count(*) from scoped_clients client where not exists(
      select 1 from scoped_documents document where document.client_id=client.id
        and document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end)
      and not exists(select 1 from public.activities activity where activity.company_id=context_row.company_id
        and activity.client_id=client.id and activity.created_at::date>=bounds_row.range_start and activity.created_at::date<bounds_row.range_end)),
    'overdue_clients',(select count(*) from open_by_client where overdue>0.005),
    'average_revenue',case when (select count(*) from sales where revenue<>0)>0
      then round((select sum(revenue) from sales)/(select count(*) from sales where revenue<>0),2) else null end,
    'top_clients',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,
      'revenue',round(revenue,2),'margin',case when context_row.can_margin then round(margin,2) else null end,
      'collected',round(collected,2),'outstanding',round(outstanding,2),'overdue',round(overdue,2),
      'share',case when total_revenue<>0 then round(revenue/abs(total_revenue)*100,2) else null end)
      order by revenue desc) from top_rows),'[]'::jsonb),
    'can_view_margin',context_row.can_margin
  ) into result;
  return result;
end
$$;

create or replace function public.get_catalog_performance_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with rows as(
    select coalesce(line.item_id,line.id) id,coalesce(item.name,line.name,'Sans designation') name,
      coalesce(item.item_type,'other') item_type,sum(line.quantity) quantity,sum(line.total_excl_tax) revenue,
      sum(line.total_excl_tax-line.quantity*line.unit_cost_snapshot) margin
    from public.document_lines line join public.documents document on document.id=line.document_id
    left join public.catalog_items item on item.id=line.item_id
    where line.company_id=context_row.company_id and document.company_id=context_row.company_id
      and document.document_type in('invoice','deposit_invoice','balance_invoice')
      and document.status not in('draft','cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null
        or document.status in('finalized','validated','sent','partially_paid','paid','overdue'))
      and document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end
      and line.line_type in('item','free_item') and not line.optional
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
    group by coalesce(line.item_id,line.id),coalesce(item.name,line.name,'Sans designation'),coalesce(item.item_type,'other')
  ), top_rows as(select * from rows order by revenue desc limit 8)
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'type',item_type,
      'quantity',round(quantity,2),'revenue',round(revenue,2),'margin',case when context_row.can_margin then round(margin,2) else null end)
      order by revenue desc),'[]'::jsonb),'can_view_margin',context_row.can_margin)
    ||jsonb_build_object(
      'best_seller',coalesce((select jsonb_build_object('id',id,'name',name,'quantity',round(quantity,2))
        from rows order by quantity desc limit 1),'null'::jsonb),
      'never_sold',(select count(*) from public.catalog_items item where item.company_id=context_row.company_id
        and item.active and not exists(select 1 from rows where rows.id=item.id)),
      'missing_price',(select count(*) from public.catalog_items item where item.company_id=context_row.company_id
        and item.active and coalesce(item.sale_price,0)<=0)
    )
  into result from top_rows;
  return result;
end
$$;

create or replace function public.get_stock_alert_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  if not context_row.can_stock then return jsonb_build_object('enabled',false,'alerts','[]'::jsonb,'count',0); end if;
  with rows as(
    select item.id,item.name,item.reference,item.unit,coalesce(sum(level.physical_quantity-level.reserved_quantity),0) available,
      coalesce(item.reorder_point,item.minimum_stock,0) threshold,item.cost_price,item.primary_supplier_id
    from public.catalog_items item left join public.stock_levels level on level.item_id=item.id
    where item.company_id=context_row.company_id and item.stock_managed and item.active
    group by item.id,item.name,item.reference,item.unit,item.reorder_point,item.minimum_stock,item.cost_price,item.primary_supplier_id
  ), alerts as(select * from rows where available<threshold order by (threshold-available) desc,name limit 8)
  select jsonb_build_object('enabled',true,'count',(select count(*) from rows where available<threshold),
    'out_of_stock',(select count(*) from rows where available<=0),
    'value',case when context_row.can_purchase_prices then round((select coalesce(sum(available*cost_price),0) from rows),2) else null end,
    'alerts',coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'reference',reference,'unit',unit,
      'available',round(available,2),'threshold',round(threshold,2),'supplier_id',primary_supplier_id,
      'to_receive',coalesce((select sum(line.quantity-line.received_quantity) from public.purchase_order_lines line
        join public.purchase_orders purchase on purchase.id=line.purchase_order_id
        where line.item_id=alerts.id and purchase.company_id=context_row.company_id
          and purchase.status in('sent','confirmed','partially_received','partial') and line.received_quantity<line.quantity),0)
      ) order by (threshold-available) desc),'[]'::jsonb))
  into result from alerts;
  return result;
end
$$;

create or replace function public.get_user_activity_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb; local_today date;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  local_today:=(clock_timestamp() at time zone bounds_row.timezone)::date;
  with activity_rows as(
    select activity.* from public.activities activity where activity.company_id=context_row.company_id
      and activity.completed_at is null and coalesce(activity.metadata->>'status','todo') not in('completed','cancelled')
      and (context_row.data_scope='company' or activity.assigned_user_id=context_row.user_id
        or activity.created_by=context_row.user_id)
  ), agenda as(
    select id,subject,activity_type,client_id,assigned_user_id,coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at) due_at,
      coalesce(metadata->>'priority','normal') priority,coalesce(metadata->>'status','todo') status
    from activity_rows where coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at) is not null
    order by coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at) limit 10
  ), notifications as(
    select notification.id,notification.title,notification.message body,
      coalesce(nullif(notification.metadata->>'severity',''),
        case when notification.notification_type in('critical','payment_overdue','stock_alert') then 'critical'
             when notification.notification_type in('warning','reminder') then 'warning' else 'info' end) severity,
      notification.created_at
    from public.notifications notification where notification.company_id=context_row.company_id
      and notification.user_id=context_row.user_id and notification.read_at is null
    order by case coalesce(nullif(notification.metadata->>'severity',''),notification.notification_type)
      when 'critical' then 1 when 'payment_overdue' then 1 when 'stock_alert' then 1
      when 'warning' then 2 when 'reminder' then 2 else 3 end,
      notification.created_at desc limit 3
  )
  select jsonb_build_object(
    'today',(select count(*) from activity_rows where (coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at) at time zone bounds_row.timezone)::date=local_today),
    'overdue',(select count(*) from activity_rows where coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at)<clock_timestamp()),
    'upcoming',(select count(*) from activity_rows where coalesce(nullif(metadata->>'due_at','')::timestamptz,scheduled_at)>=clock_timestamp()),
    'agenda',coalesce((select jsonb_agg(jsonb_build_object('id',id,'subject',subject,'type',activity_type,
      'client_id',client_id,'assigned_user_id',assigned_user_id,'due_at',due_at,'priority',priority,'status',status) order by due_at) from agenda),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(jsonb_build_object('id',id,'title',title,'body',body,'severity',severity,'created_at',created_at) order by created_at desc) from notifications),'[]'::jsonb)
  ) into result;
  return result;
end
$$;

create or replace function public.get_dashboard_recent_documents(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  with rows as(
    select document.id,document.document_type,document.number,document.status,document.issue_date,
      document.total_excl_tax,document.total_incl_tax,document.updated_at,document.client_id,document.assigned_user_id,
      coalesce(client.legal_name,client.trade_name,concat_ws(' ',client.first_name,client.last_name),'Client non renseigne') client_name,
      row_number() over(partition by document.document_type order by document.updated_at desc) position
    from public.documents document left join public.clients client on client.id=document.client_id
    where document.company_id=context_row.company_id and document.document_type in('quote','invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice')
      and document.issue_date>=bounds_row.range_start and document.issue_date<bounds_row.range_end
      and (context_row.data_scope='company' or document.assigned_user_id=context_row.user_id
        or (document.assigned_user_id is null and document.created_by=context_row.user_id))
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',document_type,'number',number,'status',status,
    'issue_date',issue_date,'total_ht',round(total_excl_tax,2),'total_ttc',round(total_incl_tax,2),
    'client_id',client_id,'client_name',client_name,'assigned_user_id',assigned_user_id,'updated_at',updated_at) order by updated_at desc),'[]'::jsonb)
  into result from rows where position<=5;
  return result;
end
$$;

create or replace function public.get_dashboard_purchase_summary(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; bounds_row record; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  select * into bounds_row from public._dashboard_period_bounds(period_key,custom_start,custom_end,comparison_mode);
  if not context_row.can_purchases then
    return jsonb_build_object('enabled',false,'open_orders',0,'open_amount',0,'expected_receipts',0);
  end if;
  select jsonb_build_object(
    'enabled',true,
    'open_orders',count(*) filter(where purchase.status in('draft','sent','confirmed','partially_received','partial')),
    'open_amount',round(coalesce(sum(purchase.total_incl_tax) filter(where purchase.status in('draft','sent','confirmed','partially_received','partial')),0),2),
    'period_amount',round(coalesce(sum(purchase.total_excl_tax) filter(where purchase.order_date>=bounds_row.range_start and purchase.order_date<bounds_row.range_end),0),2),
    'expected_receipts',coalesce((select count(*) from public.purchase_order_lines line join public.purchase_orders parent on parent.id=line.purchase_order_id where parent.company_id=context_row.company_id and line.received_quantity<line.quantity),0),
    'overdue_receipts',count(*) filter(where purchase.expected_date<(clock_timestamp() at time zone bounds_row.timezone)::date
      and purchase.status in('sent','confirmed','partially_received','partial'))
  ) into result from public.purchase_orders purchase where purchase.company_id=context_row.company_id;
  return result;
end
$$;

create or replace function public.get_dashboard_cockpit(
  period_key text default 'current_month',custom_start date default null,custom_end date default null,
  comparison_mode text default 'previous'
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare context_row record; profile_first_name text; result jsonb;
begin
  select * into context_row from public._dashboard_request_context();
  if context_row.company_id is null then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  select nullif(split_part(trim(coalesce(preference.first_name,
    user_account.raw_user_meta_data->>'first_name',user_account.raw_user_meta_data->>'given_name',
    user_account.raw_user_meta_data->>'full_name',user_account.raw_user_meta_data->>'name','')),' ',1),'')
  into profile_first_name
  from auth.users user_account left join public.user_preferences preference on preference.user_id=user_account.id
  where user_account.id=context_row.user_id;
  if profile_first_name like '%@%' or lower(coalesce(profile_first_name,'')) in('undefined','null') then profile_first_name:=null; end if;
  result:=jsonb_build_object(
    'schema_version','202607240056','generated_at',clock_timestamp(),'first_name',profile_first_name,
    'role',context_row.member_role,'summary',public.get_dashboard_summary(period_key,custom_start,custom_end,comparison_mode),
    'timeseries',public.get_revenue_timeseries(period_key,custom_start,custom_end,comparison_mode),
    'forecast',public.get_cash_collection_forecast(period_key,custom_start,custom_end,comparison_mode),
    'priority_actions',public.get_dashboard_priority_actions(period_key,custom_start,custom_end,comparison_mode),
    'receivables',public.get_receivables_dashboard_summary(period_key,custom_start,custom_end,comparison_mode),
    'funnel',public.get_sales_funnel_summary(period_key,custom_start,custom_end,comparison_mode),
    'recent_documents',public.get_dashboard_recent_documents(period_key,custom_start,custom_end,comparison_mode),
    'customers',public.get_customer_performance_summary(period_key,custom_start,custom_end,comparison_mode),
    'catalog',public.get_catalog_performance_summary(period_key,custom_start,custom_end,comparison_mode),
    'stock',public.get_stock_alert_summary(period_key,custom_start,custom_end,comparison_mode),
    'activity',public.get_user_activity_summary(period_key,custom_start,custom_end,comparison_mode),
    'purchases',public.get_dashboard_purchase_summary(period_key,custom_start,custom_end,comparison_mode),
    'preferences',public.get_dashboard_preferences()
  );
  return result;
end
$$;

revoke all on table public.dashboard_preferences from public,anon;
grant select,insert,update,delete on table public.dashboard_preferences to authenticated;
revoke all on function public._dashboard_request_context() from public,anon,authenticated;
revoke all on function public._dashboard_period_bounds(text,date,date,text) from public,anon,authenticated;
revoke all on function public.get_dashboard_preferences() from public,anon;
revoke all on function public.save_dashboard_preferences(integer,jsonb,jsonb,jsonb,jsonb,jsonb) from public,anon;
revoke all on function public.get_dashboard_summary(text,date,date,text) from public,anon;
revoke all on function public.get_revenue_timeseries(text,date,date,text) from public,anon;
revoke all on function public.get_cash_collection_forecast(text,date,date,text) from public,anon;
revoke all on function public.get_dashboard_priority_actions(text,date,date,text) from public,anon;
revoke all on function public.get_sales_funnel_summary(text,date,date,text) from public,anon;
revoke all on function public.get_receivables_dashboard_summary(text,date,date,text) from public,anon;
revoke all on function public.get_customer_performance_summary(text,date,date,text) from public,anon;
revoke all on function public.get_catalog_performance_summary(text,date,date,text) from public,anon;
revoke all on function public.get_stock_alert_summary(text,date,date,text) from public,anon;
revoke all on function public.get_user_activity_summary(text,date,date,text) from public,anon;
revoke all on function public.get_dashboard_recent_documents(text,date,date,text) from public,anon;
revoke all on function public.get_dashboard_purchase_summary(text,date,date,text) from public,anon;
revoke all on function public.get_dashboard_cockpit(text,date,date,text) from public,anon;
grant execute on function public.get_dashboard_preferences() to authenticated;
grant execute on function public.save_dashboard_preferences(integer,jsonb,jsonb,jsonb,jsonb,jsonb) to authenticated;
grant execute on function public.get_dashboard_summary(text,date,date,text) to authenticated;
grant execute on function public.get_revenue_timeseries(text,date,date,text) to authenticated;
grant execute on function public.get_cash_collection_forecast(text,date,date,text) to authenticated;
grant execute on function public.get_dashboard_priority_actions(text,date,date,text) to authenticated;
grant execute on function public.get_sales_funnel_summary(text,date,date,text) to authenticated;
grant execute on function public.get_receivables_dashboard_summary(text,date,date,text) to authenticated;
grant execute on function public.get_customer_performance_summary(text,date,date,text) to authenticated;
grant execute on function public.get_catalog_performance_summary(text,date,date,text) to authenticated;
grant execute on function public.get_stock_alert_summary(text,date,date,text) to authenticated;
grant execute on function public.get_user_activity_summary(text,date,date,text) to authenticated;
grant execute on function public.get_dashboard_recent_documents(text,date,date,text) to authenticated;
grant execute on function public.get_dashboard_purchase_summary(text,date,date,text) to authenticated;
grant execute on function public.get_dashboard_cockpit(text,date,date,text) to authenticated;

commit;
