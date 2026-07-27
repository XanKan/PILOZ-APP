-- Tableau de bord : alignement sur le catalogue central des permissions.
-- Cette migration est additive et ne modifie aucune donnée métier.
-- Elle évite notamment qu'une ancienne valeur par défaut `view_margins=false`
-- masque le droit canonique `catalog.margin.read` d'un administrateur.

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
    case
      when public.company_permission_scope(member.company_id,'dashboard.read',member.user_id)='company' then 'company'
      else 'personal'
    end,
    public.has_company_permission(member.company_id,'dashboard.read'),
    public.has_company_permission(member.company_id,'catalog.margin.read'),
    public.has_feature(member.company_id,'inventory') and (
      public.has_company_permission(member.company_id,'stock.read')
      or public.has_company_permission(member.company_id,'stock.write')
    ),
    public.has_company_permission(member.company_id,'catalog.purchase_price.read'),
    (public.has_company_permission(member.company_id,'purchases.orders.read')
      or public.has_company_permission(member.company_id,'purchases.invoices.read')),
    (public.has_company_permission(member.company_id,'sales.quotes.create')
      or public.has_company_permission(member.company_id,'sales.quotes.update_draft')
      or public.has_company_permission(member.company_id,'sales.invoices.create_draft')
      or public.has_company_permission(member.company_id,'sales.invoices.update_draft')
      or public.has_company_permission(member.company_id,'clients.write')
      or public.has_company_permission(member.company_id,'crm.opportunities.write'))
      and coalesce(company.platform_status,'active')='active'
      and coalesce(member.platform_status,'active')='active',
    (public.has_company_permission(member.company_id,'sales.quotes.create')
      or public.has_company_permission(member.company_id,'sales.quotes.update_draft')
      or public.has_company_permission(member.company_id,'sales.invoices.create_draft')
      or public.has_company_permission(member.company_id,'sales.invoices.update_draft')),
    public.has_company_permission(member.company_id,'clients.write'),
    public.has_company_permission(member.company_id,'payments.create'),
    member.role<>'read_only' and (
      public.has_company_permission(member.company_id,'crm.activities.write')
      or public.has_company_permission(member.company_id,'crm.opportunities.write')),
    public.has_company_permission(member.company_id,'catalog.write'),
    (public.has_company_permission(member.company_id,'crm.reminders.manage')
      or public.has_company_permission(member.company_id,'sales.receivables.remind'))
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

revoke all on function public._dashboard_request_context() from public,anon,authenticated;

comment on function public._dashboard_request_context() is
  'Contexte du cockpit calculé depuis les permissions canoniques et le périmètre dashboard.read.';
