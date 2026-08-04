begin;

-- Adds a dedicated, more restrictive permission for true "login as client"
-- impersonation (as opposed to the existing read-only/limited-write support
-- session, which only bookkeeps intent and grants no actual access). Only
-- super_admin gets it by default; other roles can be granted it explicitly
-- later from the Admins page if needed.
insert into public.platform_admin_permissions(role,permission) values('super_admin','support.impersonate')
on conflict do nothing;

alter table public.support_sessions drop constraint if exists support_sessions_mode_check;
alter table public.support_sessions add constraint support_sessions_mode_check
  check(mode in('read_only','limited_write','impersonate'));

create or replace function public.platform_admin_start_support_session(target_company_id uuid,target_reason text,target_mode text default 'read_only')
returns public.support_sessions language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare admin public.platform_admins%rowtype; session_row public.support_sessions%rowtype;
begin
  if not public.is_platform_admin('support.session',true) or not public.platform_admin_recent_auth(300) then raise exception 'recent_reauthentication_required' using errcode='42501'; end if;
  if target_mode='impersonate' and not public.is_platform_admin('support.impersonate',true) then raise exception 'platform_admin_access_denied' using errcode='42501'; end if;
  if nullif(trim(target_reason),'') is null then raise exception 'reason_required'; end if;
  if target_mode not in('read_only','limited_write','impersonate') then raise exception 'invalid_support_mode'; end if;
  select * into admin from public.platform_admins where user_id=auth.uid() and status='active';
  if not exists(select 1 from public.companies where id=target_company_id) then raise exception 'company_not_found'; end if;
  insert into public.support_sessions(admin_id,company_id,reason,mode,expires_at)
  values(admin.id,target_company_id,trim(target_reason),target_mode,now()+interval '30 minutes') returning * into session_row;
  perform public.append_platform_admin_audit('support.session_started','support_session',session_row.id::text,target_company_id,null,to_jsonb(session_row),target_reason);
  return session_row;
end $$;

commit;
