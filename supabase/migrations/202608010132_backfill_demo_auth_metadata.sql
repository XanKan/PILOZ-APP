begin;

-- Keep the demo identity available in the access token as well as in the
-- company tags. This repairs demo accounts created before the metadata flag
-- was written by the platform administration API.
update auth.users auth_user
set raw_user_meta_data=coalesce(auth_user.raw_user_meta_data,'{}'::jsonb)
  || jsonb_build_object('demo_account',true,'onboarding_completed',true)
from public.company_members membership
join public.companies company on company.id=membership.company_id
where membership.user_id=auth_user.id
  and (
    company.admin_tags @> array['demo']::text[]
    or company.admin_tags @> array['seeded']::text[]
  )
  and (
    lower(coalesce(auth_user.raw_user_meta_data->>'demo_account','')) not in ('true','1','yes')
    or lower(coalesce(auth_user.raw_user_meta_data->>'onboarding_completed','')) not in ('true','1','yes')
  );

commit;
