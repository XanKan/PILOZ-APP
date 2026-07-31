-- Align prospect creation with the client directory form.
-- Professional prospects keep official company data; individual prospects never
-- retain professional identifiers, even if the user changes the type mid-form.

create or replace function public.create_crm_prospect(target_payload jsonb)
returns public.clients
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  context_row record;
  result public.clients%rowtype;
  email_value text;
  kind_value text;
  legal_name_value text;
  first_name_value text;
  last_name_value text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not context_row.can_write then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;

  kind_value:=coalesce(nullif(target_payload->>'kind',''),'company');
  if kind_value not in ('company','person') then
    raise exception 'crm_invalid_prospect_kind';
  end if;

  legal_name_value:=nullif(trim(target_payload->>'legal_name'),'');
  first_name_value:=nullif(trim(target_payload->>'first_name'),'');
  last_name_value:=nullif(trim(target_payload->>'last_name'),'');

  if kind_value='company' and legal_name_value is null then
    raise exception 'crm_prospect_legal_name_required';
  end if;
  if kind_value='person' and (first_name_value is null or last_name_value is null) then
    raise exception 'crm_prospect_person_name_required';
  end if;

  email_value:=nullif(lower(trim(target_payload->>'email')),'');
  if email_value is not null and exists(
    select 1 from public.clients client
    where client.company_id=context_row.company_id
      and lower(client.email)=email_value
      and client.active
  ) then
    raise exception 'crm_duplicate_email';
  end if;

  insert into public.clients(
    company_id,kind,legal_name,trade_name,legal_form,civility,first_name,last_name,
    email,phone_e164,siren,siret,ape_code,address_line_1,address_line_2,postal_code,
    city,country_code,relationship_type,crm_status,crm_source_id,assigned_user_id,
    contact_name,created_by
  ) values (
    context_row.company_id,
    kind_value,
    case when kind_value='company' then legal_name_value else null end,
    case when kind_value='company' then nullif(trim(target_payload->>'trade_name'),'') else null end,
    case when kind_value='company' then nullif(trim(target_payload->>'legal_form'),'') else null end,
    case when kind_value='person' then nullif(trim(target_payload->>'civility'),'') else null end,
    first_name_value,
    last_name_value,
    email_value,
    nullif(trim(target_payload->>'phone_e164'),''),
    case when kind_value='company' then nullif(regexp_replace(target_payload->>'siren','\D','','g'),'') else null end,
    case when kind_value='company' then nullif(regexp_replace(target_payload->>'siret','\D','','g'),'') else null end,
    case when kind_value='company' then nullif(trim(target_payload->>'ape_code'),'') else null end,
    nullif(trim(target_payload->>'address_line_1'),''),
    nullif(trim(target_payload->>'address_line_2'),''),
    nullif(trim(target_payload->>'postal_code'),''),
    nullif(trim(target_payload->>'city'),''),
    coalesce(nullif(upper(trim(target_payload->>'country_code')),''),'FR'),
    'prospect',
    coalesce(nullif(target_payload->>'crm_status',''),'new'),
    nullif(target_payload->>'source_id','')::uuid,
    nullif(target_payload->>'assigned_user_id','')::uuid,
    nullif(trim(target_payload->>'contact_name'),''),
    auth.uid()
  ) returning * into result;

  insert into public.crm_timeline_events(
    company_id,entity_type,entity_id,event_type,title,summary,created_by
  ) values (
    result.company_id,'prospect',result.id,'prospect_created','Prospect créé',
    coalesce(result.legal_name,result.trade_name,concat_ws(' ',result.first_name,result.last_name)),
    auth.uid()
  );

  return result;
end
$$;

revoke all on function public.create_crm_prospect(jsonb) from public,anon;
grant execute on function public.create_crm_prospect(jsonb) to authenticated;

