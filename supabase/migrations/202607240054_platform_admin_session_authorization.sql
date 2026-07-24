begin;

-- Une connexion au back-office exige déjà le mot de passe puis une MFA AAL2.
-- Tant que la session serveur courte reste active, les actions autorisées par
-- le rôle ne redemandent pas ces deux facteurs. L'expiration et la révocation
-- continuent d'être contrôlées par platform_admin_validate_and_touch_session.
create or replace function public.platform_admin_recent_auth(max_age_seconds integer default 300)
returns boolean
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $$
  select public.is_platform_admin(null,true)
    and nullif(auth.jwt()->>'session_id','') is not null
    and exists(
      select 1
      from public.platform_admin_sessions session
      join public.platform_admins admin on admin.id=session.admin_id
      where admin.user_id=auth.uid()
        and admin.status='active'
        and session.auth_session_id=auth.jwt()->>'session_id'
        and session.revoked_at is null
        and session.expires_at>now()
    );
$$;

revoke all on function public.platform_admin_recent_auth(integer) from public,anon;
grant execute on function public.platform_admin_recent_auth(integer) to authenticated;

commit;
