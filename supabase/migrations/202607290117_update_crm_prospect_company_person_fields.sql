-- Keep prospect edits aligned with prospect creation.
-- Professional identifiers are cleared for individuals and individual identity
-- fields remain mandatory when a prospect changes type.

create or replace function public.update_crm_prospect(
  target_prospect_id uuid,
  target_payload jsonb
)
returns public.clients
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  context_row record;
  prospect_row public.clients%rowtype;
  email_value text;
  kind_value text;
  legal_name_value text;
  first_name_value text;
  last_name_value text;
begin
  select * into context_row from public._crm_context();
  select * into prospect_row
  from public.clients
  where id=target_prospect_id
    and company_id=context_row.company_id
    and relationship_type='prospect'
  for update;

  if prospect_row.id is null
    or not context_row.can_write
    or not (
      context_row.can_view_all
      or prospect_row.assigned_user_id=auth.uid()
      or prospect_row.created_by=auth.uid()
    ) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;

  kind_value:=coalesce(nullif(target_payload->>'kind',''),prospect_row.kind,'company');
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
      and client.id<>prospect_row.id
      and lower(client.email)=email_value
      and client.active
  ) then
    raise exception 'crm_duplicate_email';
  end if;

  update public.clients set
    kind=kind_value,
    legal_name=case when kind_value='company' then legal_name_value else null end,
    trade_name=case when kind_value='company' then nullif(trim(target_payload->>'trade_name'),'') else null end,
    legal_form=case when kind_value='company' then nullif(trim(target_payload->>'legal_form'),'') else null end,
    civility=case when kind_value='person' then nullif(trim(target_payload->>'civility'),'') else null end,
    first_name=first_name_value,
    last_name=last_name_value,
    contact_name=nullif(trim(target_payload->>'contact_name'),''),
    email=email_value,
    phone_e164=nullif(trim(target_payload->>'phone_e164'),''),
    siren=case when kind_value='company' then nullif(regexp_replace(target_payload->>'siren','\D','','g'),'') else null end,
    siret=case when kind_value='company' then nullif(regexp_replace(target_payload->>'siret','\D','','g'),'') else null end,
    ape_code=case when kind_value='company' then nullif(trim(target_payload->>'ape_code'),'') else null end,
    address_line_1=nullif(trim(target_payload->>'address_line_1'),''),
    address_line_2=nullif(trim(target_payload->>'address_line_2'),''),
    postal_code=nullif(trim(target_payload->>'postal_code'),''),
    city=nullif(trim(target_payload->>'city'),''),
    country_code=coalesce(nullif(upper(trim(target_payload->>'country_code')),''),'FR'),
    crm_status=coalesce(nullif(target_payload->>'crm_status',''),prospect_row.crm_status),
    crm_source_id=nullif(target_payload->>'source_id','')::uuid,
    assigned_user_id=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,prospect_row.assigned_user_id),
    updated_at=now()
  where id=prospect_row.id
  returning * into prospect_row;

  return prospect_row;
end
$$;

revoke all on function public.update_crm_prospect(uuid,jsonb) from public,anon;
grant execute on function public.update_crm_prospect(uuid,jsonb) to authenticated;
