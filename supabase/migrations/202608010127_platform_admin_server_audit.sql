-- Journalisation des actions effectuées par l'Edge Function d'administration.
-- La fonction publique historique reste inaccessible directement aux utilisateurs.
create or replace function public.append_platform_admin_audit_service(
  target_actor_user_id uuid,
  target_action text,
  target_type text,
  target_id text default null,
  target_company_id uuid default null,
  old_state jsonb default null,
  new_state jsonb default null,
  target_reason text default null,
  target_result text default 'success',
  target_error_code text default null,
  target_request_id uuid default gen_random_uuid()
)
returns uuid
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  admin public.platform_admins%rowtype;
  event_id uuid;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;

  select * into admin
  from public.platform_admins
  where user_id=target_actor_user_id and status='active';

  if admin.id is null then
    raise exception 'platform_admin_required' using errcode='42501';
  end if;
  if nullif(trim(target_action),'') is null or nullif(trim(target_type),'') is null then
    raise exception 'invalid_audit_event';
  end if;

  insert into public.platform_admin_audit_events(
    admin_id,admin_role,action,target_type,target_id,company_id,
    previous_state,new_state,reason,request_id,result,error_code
  )
  values(
    admin.id,admin.role,trim(target_action),trim(target_type),target_id,target_company_id,
    old_state,new_state,nullif(trim(target_reason),''),target_request_id,target_result,target_error_code
  )
  returning id into event_id;

  return event_id;
end $$;

revoke all on function public.append_platform_admin_audit_service(
  uuid,text,text,text,uuid,jsonb,jsonb,text,text,text,uuid
) from public,anon,authenticated;

grant execute on function public.append_platform_admin_audit_service(
  uuid,text,text,text,uuid,jsonb,jsonb,text,text,text,uuid
) to service_role;

comment on function public.append_platform_admin_audit_service(
  uuid,text,text,text,uuid,jsonb,jsonb,text,text,text,uuid
) is 'Ajoute un événement d audit pour un administrateur identifié. Appel réservé aux fonctions serveur.';
