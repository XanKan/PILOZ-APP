-- Provision an account from the Piloz back-office without inventing legal data.
-- The owner completes company identity, addresses, tax settings and numbering
-- during the application onboarding.

create or replace function public.platform_admin_create_company(
  target_owner_user_id uuid,target_company jsonb,target_subscription jsonb,target_reason text
) returns public.companies language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare
  admin public.platform_admins%rowtype;
  company_row public.companies%rowtype;
  version public.subscription_plan_versions%rowtype;
  plan_version_id uuid;
  billing_cycle text;
  trial_days integer;
  requested_status text;
  provisional_name text;
  provisioning_pending boolean;
  feature record;
begin
  if not public.is_platform_admin('companies.write',true) or not public.platform_admin_recent_auth(300) then
    raise exception 'recent_reauthentication_required' using errcode='42501';
  end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if not exists(select 1 from auth.users where id=target_owner_user_id) then raise exception 'owner_user_not_found'; end if;

  provisional_name:=nullif(trim(coalesce(
    target_company->>'provisioning_name',
    target_company->>'trade_name',
    target_company->>'legal_name',
    concat_ws(' ',target_company->>'owner_first_name',target_company->>'owner_last_name')
  )), '');
  if provisional_name is null then raise exception 'owner_identity_required'; end if;
  provisioning_pending:=coalesce((target_company->>'provisioning_pending')::boolean,false);

  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  plan_version_id:=nullif(target_subscription->>'plan_version_id','')::uuid;
  select * into version from public.subscription_plan_versions where id=plan_version_id and effective_to is null;
  if version.id is null then raise exception 'plan_version_not_found'; end if;
  billing_cycle:=coalesce(nullif(target_subscription->>'billing_interval',''),'monthly');
  requested_status:=coalesce(nullif(target_subscription->>'status',''),'active');
  trial_days:=greatest(0,least(365,coalesce((target_subscription->>'trial_days')::integer,14)));
  if billing_cycle not in('monthly','annual') or requested_status not in('trialing','active') then
    raise exception 'invalid_subscription_configuration';
  end if;

  insert into public.companies(owner_user_id,name,internal_admin_notes,admin_tags)
  values(
    target_owner_user_id,
    provisional_name,
    nullif(trim(target_company->>'internal_admin_notes'),''),
    case when jsonb_typeof(target_company->'admin_tags')='array'
      then array(select jsonb_array_elements_text(target_company->'admin_tags'))
      else '{}'::text[] end
  ) returning * into company_row;

  insert into public.company_members(company_id,user_id,role)
  values(company_row.id,target_owner_user_id,'owner')
  on conflict(company_id,user_id) do update set
    role='owner',platform_status='active',suspended_at=null,suspension_reason=null,updated_at=now();

  insert into public.user_preferences(user_id,company_id,onboarding_completed,first_name,last_name,display_name)
  values(
    target_owner_user_id,
    company_row.id,
    false,
    nullif(trim(target_company->>'owner_first_name'),''),
    nullif(trim(target_company->>'owner_last_name'),''),
    nullif(trim(concat_ws(' ',target_company->>'owner_first_name',target_company->>'owner_last_name')),'')
  )
  on conflict(user_id) do update set
    company_id=excluded.company_id,
    onboarding_completed=false,
    first_name=coalesce(excluded.first_name,public.user_preferences.first_name),
    last_name=coalesce(excluded.last_name,public.user_preferences.last_name),
    display_name=coalesce(excluded.display_name,public.user_preferences.display_name),
    updated_at=now();

  -- Legal and operational fields deliberately remain NULL for the simplified
  -- back-office flow. Older callers that provide verified values remain supported.
  insert into public.company_settings(
    company_id,legal_name,trade_name,company_type,siren,siret,address_line1,address_line2,postal_code,city,
    country,country_code,email,phone,currency,language,legal_form,onboarding_step,onboarding_completed_at
  ) values(
    company_row.id,
    case when provisioning_pending then null else nullif(trim(target_company->>'legal_name'),'') end,
    case when provisioning_pending then null else nullif(trim(target_company->>'trade_name'),'') end,
    case when provisioning_pending then null else nullif(trim(target_company->>'company_type'),'') end,
    case when provisioning_pending then null else nullif(trim(target_company->>'siren'),'') end,
    case when provisioning_pending then null else nullif(trim(target_company->>'siret'),'') end,
    nullif(trim(target_company->>'address_line1'),''),
    nullif(trim(target_company->>'address_line2'),''),
    nullif(trim(target_company->>'postal_code'),''),
    nullif(trim(target_company->>'city'),''),
    coalesce(nullif(trim(target_company->>'country'),''),'France'),
    coalesce(nullif(upper(trim(target_company->>'country_code')),''),'FR'),
    nullif(trim(target_company->>'email'),''),
    nullif(trim(target_company->>'phone'),''),
    coalesce(nullif(upper(trim(target_company->>'currency')),''),'EUR'),
    coalesce(nullif(lower(trim(target_company->>'language')),''),'fr'),
    case when provisioning_pending then null else nullif(trim(target_company->>'legal_form'),'') end,
    1,
    null
  ) on conflict(company_id) do nothing;

  update public.subscriptions set
    plan_key=version.plan_key,
    plan_version_id=version.id,
    billing_interval=billing_cycle,
    status=requested_status,
    trial_started_at=case when requested_status='trialing' then now() else null end,
    trial_ends_at=case when requested_status='trialing' then now()+make_interval(days=>trial_days) else null end,
    subscription_started_at=case when requested_status='active' then now() else null end,
    contract_monthly_cents=version.price_monthly_cents,
    contract_annual_cents=version.price_annual_cents,
    max_users_override=nullif(target_subscription->>'max_users','')::integer,
    provider='manual',payment_status='not_configured',updated_at=now()
  where company_id=company_row.id;

  for feature in select key,value from jsonb_each(coalesce(target_subscription->'feature_overrides','{}'::jsonb)) loop
    insert into public.company_feature_overrides(company_id,feature_key,enabled,reason,created_by)
    values(company_row.id,feature.key,(feature.value #>> '{}')::boolean,'Configuration a la creation',admin.id);
  end loop;

  perform public.append_platform_admin_audit(
    'company.create','company',company_row.id::text,company_row.id,null,
    jsonb_build_object('company',to_jsonb(company_row),'subscription',target_subscription,'onboarding_pending',true),
    target_reason
  );
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values(
    'company_created','info','Nouvelle entreprise',
    company_row.name||' a ete creee et doit terminer son onboarding.',
    company_row.id,'/companies/'||company_row.id::text
  );
  return company_row;
end $$;

revoke all on function public.platform_admin_create_company(uuid,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.platform_admin_create_company(uuid,jsonb,jsonb,text) to authenticated,service_role;
