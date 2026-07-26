begin;

-- Opérations CRM avancées : administration des pipelines, édition atomique,
-- fusion/import contrôlés et recherche globale. Aucune suppression métier.

create or replace function public.update_crm_pipeline(target_pipeline_id uuid,target_patch jsonb)
returns public.crm_pipelines language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;pipeline_row public.crm_pipelines%rowtype;requested_status text;make_default boolean;
begin
  select * into context_row from public._crm_context();
  select * into pipeline_row from public.crm_pipelines where id=target_pipeline_id and company_id=context_row.company_id for update;
  if pipeline_row.id is null or not context_row.can_manage then raise exception 'crm_forbidden' using errcode='42501'; end if;
  requested_status:=case when target_patch ? 'status' then nullif(target_patch->>'status','') else pipeline_row.status end;
  make_default:=case when target_patch ? 'is_default' then coalesce((target_patch->>'is_default')::boolean,false) else pipeline_row.is_default end;
  if requested_status not in('draft','active','inactive','archived') then raise exception 'crm_invalid_pipeline_status'; end if;
  if requested_status='archived' and pipeline_row.is_default then raise exception 'crm_default_pipeline_cannot_be_archived'; end if;
  if make_default and requested_status<>'active' then raise exception 'crm_default_pipeline_must_be_active'; end if;
  if make_default then update public.crm_pipelines set is_default=false,updated_by=auth.uid(),updated_at=now() where company_id=context_row.company_id and id<>pipeline_row.id and is_default; end if;
  update public.crm_pipelines set
    name=case when target_patch ? 'name' then coalesce(nullif(trim(target_patch->>'name'),''),name) else name end,
    description=case when target_patch ? 'description' then nullif(trim(target_patch->>'description'),'') else description end,
    pipeline_type=case when target_patch ? 'pipeline_type' then coalesce(nullif(target_patch->>'pipeline_type',''),pipeline_type) else pipeline_type end,
    status=requested_status,
    owner_user_id=case when target_patch ? 'owner_user_id' then nullif(target_patch->>'owner_user_id','')::uuid else owner_user_id end,
    color=case when target_patch ? 'color' then coalesce(nullif(target_patch->>'color',''),color) else color end,
    currency=case when target_patch ? 'currency' then coalesce(nullif(target_patch->>'currency',''),currency) else currency end,
    position=case when target_patch ? 'position' then coalesce((target_patch->>'position')::integer,position) else position end,
    is_default=make_default,updated_by=auth.uid(),updated_at=now()
  where id=pipeline_row.id returning * into pipeline_row;
  return pipeline_row;
end
$$;

create or replace function public.upsert_crm_pipeline_stage(target_pipeline_id uuid,target_stage jsonb)
returns public.pipeline_stages language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;pipeline_row public.crm_pipelines%rowtype;stage_row public.pipeline_stages%rowtype;stage_id uuid;stage_kind text;stage_name text;
begin
  select * into context_row from public._crm_context();
  select * into pipeline_row from public.crm_pipelines where id=target_pipeline_id and company_id=context_row.company_id and status<>'archived';
  if pipeline_row.id is null or not context_row.can_manage then raise exception 'crm_forbidden' using errcode='42501'; end if;
  stage_id:=nullif(target_stage->>'id','')::uuid;stage_name:=nullif(trim(target_stage->>'name'),'');stage_kind:=coalesce(nullif(target_stage->>'stage_type',''),'open');
  if stage_name is null or stage_kind not in('open','won','lost','suspended') then raise exception 'crm_invalid_stage'; end if;
  if stage_id is null then
    insert into public.pipeline_stages(company_id,pipeline_id,name,slug,description,position,probability,color,active,is_won,is_lost,stage_type,recommended_delay_days,entry_rules,exit_rules,automation_rules,created_by,updated_by)
    values(context_row.company_id,pipeline_row.id,stage_name,pipeline_row.slug||'-'||public._crm_slug(stage_name)||'-'||substr(gen_random_uuid()::text,1,4),nullif(target_stage->>'description',''),
      coalesce(nullif(target_stage->>'position','')::integer,(select coalesce(max(position),0)+10 from public.pipeline_stages where pipeline_id=pipeline_row.id)),
      least(100,greatest(0,coalesce(nullif(target_stage->>'probability','')::numeric,10))),coalesce(nullif(target_stage->>'color',''),'#14b8a6'),true,stage_kind='won',stage_kind='lost',stage_kind,
      nullif(target_stage->>'recommended_delay_days','')::integer,coalesce(target_stage->'entry_rules','{}'::jsonb),coalesce(target_stage->'exit_rules','{}'::jsonb),coalesce(target_stage->'automation_rules','[]'::jsonb),auth.uid(),auth.uid()) returning * into stage_row;
  else
    update public.pipeline_stages set name=stage_name,description=nullif(target_stage->>'description',''),stage_type=stage_kind,is_won=stage_kind='won',is_lost=stage_kind='lost',
      probability=least(100,greatest(0,coalesce(nullif(target_stage->>'probability','')::numeric,probability))),color=coalesce(nullif(target_stage->>'color',''),color),
      recommended_delay_days=nullif(target_stage->>'recommended_delay_days','')::integer,active=coalesce((target_stage->>'active')::boolean,active),updated_by=auth.uid(),updated_at=now()
    where id=stage_id and company_id=context_row.company_id and pipeline_id=pipeline_row.id returning * into stage_row;
    if stage_row.id is null then raise exception 'crm_stage_not_found' using errcode='P0002'; end if;
  end if;
  return stage_row;
end
$$;

create or replace function public.reorder_crm_pipeline_stages(target_pipeline_id uuid,target_stage_ids uuid[])
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;expected_count integer;
begin
  select * into context_row from public._crm_context();
  if not context_row.can_manage or not exists(select 1 from public.crm_pipelines where id=target_pipeline_id and company_id=context_row.company_id) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  select count(*) into expected_count from public.pipeline_stages where pipeline_id=target_pipeline_id and company_id=context_row.company_id and active;
  if coalesce(array_length(target_stage_ids,1),0)<>expected_count or exists(select 1 from unnest(target_stage_ids) value where not exists(select 1 from public.pipeline_stages stage where stage.id=value and stage.pipeline_id=target_pipeline_id and stage.active)) then raise exception 'crm_invalid_stage_order'; end if;
  update public.pipeline_stages stage set position=ordered.position*10,updated_by=auth.uid(),updated_at=now()
  from(select value id,row_number() over() position from unnest(target_stage_ids) value)ordered where stage.id=ordered.id;
end
$$;

create or replace function public.update_crm_opportunity(target_opportunity_id uuid,target_payload jsonb)
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;pipeline_row public.crm_pipelines%rowtype;stage_row public.pipeline_stages%rowtype;previous_stage uuid;
begin
  select * into context_row from public._crm_context();
  select * into opportunity_row from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
  if opportunity_row.id is null or not context_row.can_write or not(context_row.can_view_all or opportunity_row.assigned_user_id=auth.uid() or opportunity_row.created_by=auth.uid()) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  select * into pipeline_row from public.crm_pipelines where id=coalesce(nullif(target_payload->>'pipeline_id','')::uuid,opportunity_row.pipeline_id) and company_id=context_row.company_id and status='active';
  select * into stage_row from public.pipeline_stages where id=coalesce(nullif(target_payload->>'stage_id','')::uuid,opportunity_row.pipeline_stage_id) and company_id=context_row.company_id and pipeline_id=pipeline_row.id and active;
  if nullif(trim(target_payload->>'name'),'') is null or pipeline_row.id is null or stage_row.id is null then raise exception 'crm_invalid_opportunity'; end if;
  if stage_row.stage_type in('won','lost') then raise exception 'crm_close_dialog_required'; end if;
  previous_stage:=opportunity_row.pipeline_stage_id;
  update public.opportunities set name=trim(target_payload->>'name'),client_id=nullif(target_payload->>'client_id','')::uuid,
    pipeline_id=pipeline_row.id,pipeline_stage_id=stage_row.id,stage=stage_row.slug,amount=coalesce(nullif(target_payload->>'amount','')::numeric,0),
    probability=least(100,greatest(0,coalesce(nullif(target_payload->>'probability','')::numeric,stage_row.probability))),expected_close_date=nullif(target_payload->>'expected_close_date','')::date,
    assigned_user_id=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,assigned_user_id,auth.uid()),owner_user_id=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,owner_user_id,auth.uid()),
    source_id=nullif(target_payload->>'source_id','')::uuid,priority=coalesce(nullif(target_payload->>'priority',''),'normal'),next_action=nullif(target_payload->>'next_action',''),
    next_action_at=nullif(target_payload->>'next_action_at','')::timestamptz,description=nullif(target_payload->>'description',''),stage_entered_at=case when previous_stage is distinct from stage_row.id then now() else stage_entered_at end,
    updated_by=auth.uid(),updated_at=now() where id=opportunity_row.id returning * into opportunity_row;
  if previous_stage is distinct from stage_row.id then
    insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
    values(opportunity_row.company_id,'opportunity',opportunity_row.id,'stage_changed','Étape modifiée',stage_row.name,jsonb_build_object('from_stage_id',previous_stage,'to_stage_id',stage_row.id),auth.uid());
  end if;
  return opportunity_row;
end
$$;

create or replace function public.update_crm_prospect(target_prospect_id uuid,target_payload jsonb)
returns public.clients language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;prospect_row public.clients%rowtype;email_value text;
begin
  select * into context_row from public._crm_context();
  select * into prospect_row from public.clients where id=target_prospect_id and company_id=context_row.company_id and relationship_type='prospect' for update;
  if prospect_row.id is null or not context_row.can_write or not(context_row.can_view_all or prospect_row.assigned_user_id=auth.uid() or prospect_row.created_by=auth.uid()) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  email_value:=nullif(lower(trim(target_payload->>'email')),'');
  if email_value is not null and exists(select 1 from public.clients client where client.company_id=context_row.company_id and client.id<>prospect_row.id and lower(client.email)=email_value and client.active) then raise exception 'crm_duplicate_email'; end if;
  update public.clients set kind=coalesce(nullif(target_payload->>'kind',''),kind),legal_name=nullif(trim(target_payload->>'legal_name'),''),trade_name=nullif(trim(target_payload->>'trade_name'),''),
    first_name=nullif(trim(target_payload->>'first_name'),''),last_name=nullif(trim(target_payload->>'last_name'),''),contact_name=nullif(trim(target_payload->>'contact_name'),''),
    email=email_value,phone_e164=nullif(trim(target_payload->>'phone_e164'),''),siren=nullif(trim(target_payload->>'siren'),''),siret=nullif(trim(target_payload->>'siret'),''),
    address_line_1=nullif(trim(target_payload->>'address_line_1'),''),address_line_2=nullif(trim(target_payload->>'address_line_2'),''),postal_code=nullif(trim(target_payload->>'postal_code'),''),
    city=nullif(trim(target_payload->>'city'),''),country_code=coalesce(nullif(upper(trim(target_payload->>'country_code')),''),country_code),
    crm_status=coalesce(nullif(target_payload->>'crm_status',''),crm_status),crm_source_id=nullif(target_payload->>'source_id','')::uuid,assigned_user_id=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,assigned_user_id),updated_at=now()
  where id=prospect_row.id returning * into prospect_row;
  return prospect_row;
end
$$;

create or replace function public.merge_crm_prospects(target_keep_id uuid,target_merge_id uuid,target_fields jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;kept public.clients%rowtype;merged public.clients%rowtype;
begin
  select * into context_row from public._crm_context();
  if target_keep_id=target_merge_id or not context_row.can_write then raise exception 'crm_invalid_merge'; end if;
  select * into kept from public.clients where id=target_keep_id and company_id=context_row.company_id and relationship_type in('prospect','client') for update;
  select * into merged from public.clients where id=target_merge_id and company_id=context_row.company_id and relationship_type='prospect' for update;
  if kept.id is null or merged.id is null then raise exception 'crm_merge_target_not_found' using errcode='P0002'; end if;
  update public.client_contacts set is_primary=false where client_id=merged.id and exists(select 1 from public.client_contacts where client_id=kept.id and is_primary);
  update public.client_contacts set client_id=kept.id,updated_by=auth.uid(),updated_at=now() where client_id=merged.id;
  update public.client_contact_roles set client_id=kept.id where client_id=merged.id;
  update public.opportunities set client_id=kept.id,updated_by=auth.uid(),updated_at=now() where client_id=merged.id;
  update public.activities set client_id=kept.id,updated_at=now() where client_id=merged.id;
  update public.documents set client_id=kept.id,updated_at=now() where client_id=merged.id;
  update public.reminders set client_id=kept.id,updated_at=now() where client_id=merged.id;
  insert into public.crm_tag_assignments(company_id,tag_id,entity_type,entity_id,created_by,updated_by)
  select company_id,tag_id,case when kept.relationship_type='client' then 'client' else 'prospect' end,kept.id,auth.uid(),auth.uid() from public.crm_tag_assignments where company_id=context_row.company_id and entity_type='prospect' and entity_id=merged.id on conflict do nothing;
  delete from public.crm_tag_assignments where company_id=context_row.company_id and entity_type='prospect' and entity_id=merged.id;
  update public.clients set legal_name=coalesce(nullif(target_fields->>'legal_name',''),kept.legal_name,merged.legal_name),email=coalesce(nullif(lower(trim(target_fields->>'email')),''),kept.email,merged.email),
    phone_e164=coalesce(nullif(target_fields->>'phone_e164',''),kept.phone_e164,merged.phone_e164),siren=coalesce(nullif(target_fields->>'siren',''),kept.siren,merged.siren),siret=coalesce(nullif(target_fields->>'siret',''),kept.siret,merged.siret),updated_at=now() where id=kept.id;
  update public.clients set relationship_type='archived',crm_status='converted',active=false,converted_at=now(),converted_from_prospect_id=kept.id,updated_at=now() where id=merged.id;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,related_type,related_id,payload,created_by)
  values(context_row.company_id,case when kept.relationship_type='client' then 'client' else 'prospect' end,kept.id,'prospect_merged','Doublon fusionné',coalesce(merged.legal_name,merged.email),'prospect',merged.id,jsonb_build_object('merged_id',merged.id),auth.uid());
  return jsonb_build_object('kept_id',kept.id,'merged_id',merged.id,'history_preserved',true);
end
$$;

create or replace function public.import_crm_prospects(target_rows jsonb,target_duplicate_action text default 'skip')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;row_data jsonb;existing public.clients%rowtype;created_row public.clients%rowtype;created_count integer:=0;updated_count integer:=0;skipped_count integer:=0;error_count integer:=0;line_no integer:=0;report jsonb:='[]'::jsonb;email_value text;
begin
  select * into context_row from public._crm_context();
  if not context_row.can_write then raise exception 'crm_forbidden' using errcode='42501'; end if;
  if jsonb_typeof(target_rows)<>'array' or jsonb_array_length(target_rows)>5000 or target_duplicate_action not in('skip','update','create') then raise exception 'crm_invalid_import'; end if;
  for row_data in select value from jsonb_array_elements(target_rows) loop
    line_no:=line_no+1;existing:=null;email_value:=nullif(lower(trim(row_data->>'email')),'');
    begin
      if nullif(trim(coalesce(row_data->>'legal_name',row_data->>'last_name',row_data->>'email',row_data->>'phone_e164',row_data->>'siret')),'') is null then raise exception 'empty_row'; end if;
      select * into existing from public.clients client where client.company_id=context_row.company_id and client.active and(
        email_value is not null and lower(client.email)=email_value or nullif(row_data->>'phone_e164','') is not null and client.phone_e164=row_data->>'phone_e164' or
        nullif(row_data->>'siret','') is not null and client.siret=row_data->>'siret' or nullif(row_data->>'siren','') is not null and client.siren=row_data->>'siren') limit 1;
      if existing.id is not null and target_duplicate_action='skip' then skipped_count:=skipped_count+1;report:=report||jsonb_build_array(jsonb_build_object('line',line_no,'status','skipped','duplicate_id',existing.id));continue; end if;
      if existing.id is not null and target_duplicate_action='update' then
        update public.clients set legal_name=coalesce(nullif(row_data->>'legal_name',''),legal_name),first_name=coalesce(nullif(row_data->>'first_name',''),first_name),last_name=coalesce(nullif(row_data->>'last_name',''),last_name),
          email=coalesce(email_value,email),phone_e164=coalesce(nullif(row_data->>'phone_e164',''),phone_e164),siren=coalesce(nullif(row_data->>'siren',''),siren),siret=coalesce(nullif(row_data->>'siret',''),siret),
          crm_status=coalesce(nullif(row_data->>'crm_status',''),crm_status),updated_at=now() where id=existing.id;
        updated_count:=updated_count+1;report:=report||jsonb_build_array(jsonb_build_object('line',line_no,'status','updated','id',existing.id));continue;
      end if;
      insert into public.clients(company_id,kind,legal_name,first_name,last_name,email,phone_e164,siren,siret,address_line_1,postal_code,city,country_code,relationship_type,crm_status,assigned_user_id,created_by)
      values(context_row.company_id,coalesce(nullif(row_data->>'kind',''),'company'),nullif(trim(row_data->>'legal_name'),''),nullif(trim(row_data->>'first_name'),''),nullif(trim(row_data->>'last_name'),''),email_value,nullif(row_data->>'phone_e164',''),nullif(row_data->>'siren',''),nullif(row_data->>'siret',''),nullif(row_data->>'address_line_1',''),nullif(row_data->>'postal_code',''),nullif(row_data->>'city',''),coalesce(nullif(row_data->>'country_code',''),'FR'),'prospect',coalesce(nullif(row_data->>'crm_status',''),'new'),coalesce(nullif(row_data->>'assigned_user_id','')::uuid,auth.uid()),auth.uid()) returning * into created_row;
      created_count:=created_count+1;report:=report||jsonb_build_array(jsonb_build_object('line',line_no,'status','created','id',created_row.id));
    exception when others then error_count:=error_count+1;report:=report||jsonb_build_array(jsonb_build_object('line',line_no,'status','error','message',sqlerrm));
    end;
  end loop;
  return jsonb_build_object('created',created_count,'updated',updated_count,'skipped',skipped_count,'errors',error_count,'rows',report);
end
$$;

create or replace function public.search_crm_global(target_query text,target_limit integer default 20)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;needle text;
begin
  select * into context_row from public._crm_context();if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501'; end if;
  needle:='%'||lower(trim(coalesce(target_query,'')))||'%';if length(trim(coalesce(target_query,'')))<2 then return '[]'::jsonb;end if;
  return coalesce((with results as(
    select 1 rank,client.id,case when client.relationship_type='prospect' then 'prospect' else 'client' end entity_type,coalesce(client.legal_name,client.trade_name,client.first_name||' '||client.last_name) title,coalesce(client.email,client.phone_e164,'') subtitle,
      case when client.relationship_type='prospect' then 'crm/prospects/'||client.id else 'sales/clients' end path
    from public.clients client where client.company_id=context_row.company_id and client.active and lower(coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(client.first_name,'')||' '||coalesce(client.last_name,'')||' '||coalesce(client.email,'')||' '||coalesce(client.phone_e164,'')) like needle and(context_row.can_view_all or client.assigned_user_id=auth.uid())
    union all select 2,opportunity.id,'opportunity',opportunity.name,coalesce(opportunity.next_action,''),'crm/pipeline/'||opportunity.id from public.opportunities opportunity where opportunity.company_id=context_row.company_id and opportunity.archived_at is null and lower(coalesce(opportunity.name,'')||' '||coalesce(opportunity.description,'')) like needle and(context_row.can_view_all or opportunity.assigned_user_id=auth.uid())
    union all select 3,document.id,'document',coalesce(document.number,'Brouillon'),coalesce(document.subject,''),case when document.document_type='quote' then 'sales/quotes' else 'sales/invoices' end from public.documents document where document.company_id=context_row.company_id and lower(coalesce(document.number,'')||' '||coalesce(document.subject,'')) like needle
    union all select 4,activity.id,'activity',activity.subject,coalesce(activity.description,''),'crm/activities' from public.activities activity where activity.company_id=context_row.company_id and lower(coalesce(activity.subject,'')||' '||coalesce(activity.description,'')) like needle and(context_row.can_view_all or activity.assigned_user_id=auth.uid())
  )select jsonb_agg(jsonb_build_object('id',id,'type',entity_type,'title',title,'subtitle',subtitle,'path',path) order by rank,title) from(select * from results order by rank,title limit least(50,greatest(1,target_limit)))limited),'[]'::jsonb);
end
$$;

revoke all on function public.update_crm_pipeline(uuid,jsonb) from public,anon;
revoke all on function public.upsert_crm_pipeline_stage(uuid,jsonb) from public,anon;
revoke all on function public.reorder_crm_pipeline_stages(uuid,uuid[]) from public,anon;
revoke all on function public.update_crm_opportunity(uuid,jsonb) from public,anon;
revoke all on function public.update_crm_prospect(uuid,jsonb) from public,anon;
revoke all on function public.merge_crm_prospects(uuid,uuid,jsonb) from public,anon;
revoke all on function public.import_crm_prospects(jsonb,text) from public,anon;
revoke all on function public.search_crm_global(text,integer) from public,anon;
grant execute on function public.update_crm_pipeline(uuid,jsonb),public.upsert_crm_pipeline_stage(uuid,jsonb),public.reorder_crm_pipeline_stages(uuid,uuid[]),
  public.update_crm_opportunity(uuid,jsonb),public.update_crm_prospect(uuid,jsonb),public.merge_crm_prospects(uuid,uuid,jsonb),public.import_crm_prospects(jsonb,text),public.search_crm_global(text,integer) to authenticated;

commit;
