begin;

-- PostgreSQL considérait feature_key comme ambigu entre le paramètre de la
-- fonction et company_feature_overrides.feature_key. Les références
-- positionnelles conservent la signature publique tout en supprimant cette
-- ambiguïté, sans modifier les données ni les droits existants.
create or replace function public.has_feature(target_company_id uuid,feature_key text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  override_value boolean;
  subscription public.subscriptions%rowtype;
  features jsonb;
begin
  if auth.uid() is not null
    and not public.is_company_member(target_company_id)
    and not public.is_platform_admin('companies.read',true)
  then
    return false;
  end if;

  select feature.enabled
    into override_value
  from public.company_feature_overrides feature
  where feature.company_id=target_company_id
    and feature.feature_key=$2
    and feature.starts_at<=now()
    and (feature.ends_at is null or feature.ends_at>now())
  order by feature.starts_at desc
  limit 1;

  if override_value is not null then
    return override_value;
  end if;

  select *
    into subscription
  from public.subscriptions
  where company_id=target_company_id
    and status in('trialing','active','past_due');

  if subscription.company_id is null then
    return false;
  end if;

  if subscription.feature_overrides ? $2 then
    return coalesce((subscription.feature_overrides->>$2)::boolean,false);
  end if;

  select version.features
    into features
  from public.subscription_plan_versions version
  where version.id=subscription.plan_version_id;

  if features is null then
    select plan.features
      into features
    from public.plans plan
    where plan.key=subscription.plan_key;
  end if;

  return coalesce(features ? $2,false);
end $$;

revoke execute on function public.has_feature(uuid,text) from public,anon;
grant execute on function public.has_feature(uuid,text) to authenticated,service_role;

commit;
