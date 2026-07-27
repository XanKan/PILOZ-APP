-- Preserve the official company information selected from the INPI search when
-- a client or prospect is created directly from the commercial pipeline.
create or replace function public.create_crm_party(target_payload jsonb)
returns public.clients
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  context_row record;
  result public.clients%rowtype;
  relationship_value text;
  kind_value text;
  display_name text;
  email_value text;
  assigned_value uuid;
  team_value uuid;
  permission_key text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;

  relationship_value:=coalesce(nullif(target_payload->>'relationship_type',''),'prospect');
  kind_value:=coalesce(nullif(target_payload->>'kind',''),'company');
  if relationship_value not in('client','prospect') or kind_value not in('company','person') then
    raise exception 'crm_invalid_party';
  end if;

  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,auth.uid());
  team_value:=nullif(target_payload->>'team_id','')::uuid;
  permission_key:=case when relationship_value='prospect' then 'crm.prospects.write' else 'clients.write' end;
  if not public._crm_has_scope(context_row.company_id,permission_key,assigned_value,team_value) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;

  display_name:=trim(coalesce(
    nullif(target_payload->>'legal_name',''),
    nullif(target_payload->>'trade_name',''),
    nullif(concat_ws(' ',target_payload->>'first_name',target_payload->>'last_name'),''),
    ''
  ));
  if display_name='' then raise exception 'crm_party_name_required'; end if;

  email_value:=nullif(lower(trim(target_payload->>'email')),'');
  if email_value is not null and exists(
    select 1 from public.clients
    where company_id=context_row.company_id and lower(email)=email_value and active
  ) then
    raise exception 'crm_duplicate_email';
  end if;

  insert into public.clients(
    company_id,kind,legal_name,trade_name,legal_form,first_name,last_name,email,
    phone_e164,siren,siret,ape_code,address_line_1,address_line_2,postal_code,city,
    country_code,relationship_type,crm_status,assigned_user_id,team_id,contact_name,created_by
  ) values (
    context_row.company_id,kind_value,display_name,nullif(trim(target_payload->>'trade_name'),''),
    nullif(trim(target_payload->>'legal_form'),''),nullif(trim(target_payload->>'first_name'),''),
    nullif(trim(target_payload->>'last_name'),''),email_value,
    nullif(trim(target_payload->>'phone_e164'),''),nullif(regexp_replace(target_payload->>'siren','\D','','g'),''),
    nullif(regexp_replace(target_payload->>'siret','\D','','g'),''),nullif(trim(target_payload->>'ape_code'),''),
    nullif(trim(target_payload->>'address_line_1'),''),nullif(trim(target_payload->>'address_line_2'),''),
    nullif(trim(target_payload->>'postal_code'),''),nullif(trim(target_payload->>'city'),''),
    coalesce(nullif(upper(trim(target_payload->>'country_code')),''),'FR'),relationship_value,
    case when relationship_value='prospect' then 'new' else 'converted' end,
    assigned_value,team_value,nullif(trim(target_payload->>'contact_name'),''),auth.uid()
  ) returning * into result;

  insert into public.crm_timeline_events(
    company_id,entity_type,entity_id,event_type,title,summary,created_by
  ) values (
    result.company_id,result.relationship_type,result.id,result.relationship_type||'_created',
    case when result.relationship_type='client' then 'Client créé' else 'Prospect créé' end,
    display_name,auth.uid()
  );
  return result;
end
$$;

revoke all on function public.create_crm_party(jsonb) from public,anon;
grant execute on function public.create_crm_party(jsonb) to authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.48';
