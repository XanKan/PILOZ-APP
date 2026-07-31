begin;

-- Keep a provisioned company visible to PILOZ-ADMIN before its owner accepts
-- the invitation. No onboarding or customer business data is fabricated.
create or replace function public.platform_admin_list_companies_v2(
  search_text text default null,
  status_filter text default null,
  plan_filter text default null,
  page_number integer default 1,
  page_size integer default 25
) returns table(
  company_id uuid,
  company_name text,
  trade_name text,
  identifier text,
  owner_email text,
  phone text,
  plan_key text,
  subscription_status text,
  trial_ends_at timestamptz,
  user_count bigint,
  created_at timestamptz,
  last_activity_at timestamptz,
  mrr_cents integer,
  account_status text,
  owner_created_at timestamptz,
  owner_last_sign_in_at timestamptz,
  activation_status text,
  total_count bigint
)
language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
begin
  if not public.is_platform_admin('companies.read',true) then
    raise exception 'platform_admin_access_denied' using errcode='42501';
  end if;

  page_number:=greatest(1,page_number);
  page_size:=greatest(1,least(page_size,100));

  return query
  select
    company.id,
    coalesce(setting.legal_name,company.name),
    setting.trade_name,
    company.id::text,
    owner.email::text,
    setting.phone,
    subscription.plan_key,
    subscription.status,
    subscription.trial_ends_at,
    (select count(*) from public.company_members member where member.company_id=company.id),
    company.created_at,
    greatest(company.updated_at,subscription.updated_at),
    public.subscription_mrr_cents(subscription),
    company.platform_status,
    owner.created_at,
    owner.last_sign_in_at,
    case
      when owner.id is null then 'owner_missing'
      when owner.last_sign_in_at is null then 'invitation_pending'
      else 'active'
    end,
    count(*) over()
  from public.companies company
  left join public.company_settings setting on setting.company_id=company.id
  left join public.subscriptions subscription on subscription.company_id=company.id
  left join auth.users owner on owner.id=company.owner_user_id
  where (
      status_filter is null or status_filter=''
      or (status_filter='invitation_pending' and owner.id is not null and owner.last_sign_in_at is null)
      or (status_filter='owner_missing' and owner.id is null)
      or (status_filter='active' and company.platform_status='active' and owner.last_sign_in_at is not null)
      or company.platform_status=status_filter
      or subscription.status=status_filter
    )
    and (plan_filter is null or plan_filter='' or subscription.plan_key=plan_filter)
    and (
      search_text is null or trim(search_text)='' or
      concat_ws(' ',company.id,company.name,setting.legal_name,setting.trade_name,
        setting.siret,setting.email,owner.email,subscription.plan_key) ilike '%'||trim(search_text)||'%'
    )
  order by company.created_at desc
  offset (page_number-1)*page_size limit page_size;
end $$;

revoke all on function public.platform_admin_list_companies_v2(text,text,text,integer,integer) from public,anon;
grant execute on function public.platform_admin_list_companies_v2(text,text,text,integer,integer) to authenticated,service_role;

commit;
