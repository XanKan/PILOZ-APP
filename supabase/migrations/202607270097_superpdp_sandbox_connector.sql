begin;

-- Connecteur SUPER PDP externe en bac à sable. Les identifiants restent dans
-- les secrets des Edge Functions ; cette table ne conserve que des métadonnées
-- non sensibles sur l'entreprise synthétique reliée.
create or replace function public.configure_superpdp_sandbox_connector(
  target_company_id uuid,
  target_external_company jsonb
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare connector_id uuid; external_environment text:=coalesce(target_external_company->>'env','');
begin
  if not public.has_company_permission(target_company_id,'electronic_invoice_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if external_environment<>'sandbox' then raise exception 'superpdp_sandbox_required'; end if;
  insert into public.platform_connectors(
    company_id,connector_code,provider_name,connector_kind,environment,status,is_simulation,production_enabled,
    credential_secret_ref,base_url,capabilities,non_secret_configuration,created_by,updated_at
  ) values(
    target_company_id,'SUPERPDP','SUPER PDP','sandbox','sandbox','tested',false,false,
    'supabase:SUPERPDP_CLIENT_SECRET','https://api.superpdp.tech',
    jsonb_build_object('send_invoice',true,'receive_invoice',true,'statuses',true,'e_reporting',true,'webhooks',true,
      'formats',jsonb_build_array('factur-x','cii','ubl'),'afnor_flow_api',true),
    jsonb_build_object(
      'display_label','SUPER PDP · Bac à sable','external_network',true,
      'external_company_id',target_external_company->'id','external_company_number',target_external_company->'number',
      'external_company_number_scheme',target_external_company->'number_scheme',
      'external_company_name',coalesce(target_external_company->'trade_name',target_external_company->'formal_name'),
      'preferred_format','factur-x','verified_at',now()
    ),auth.uid(),now()
  )
  on conflict(company_id,connector_code,environment) do update set
    provider_name=excluded.provider_name,status='tested',is_simulation=false,production_enabled=false,
    credential_secret_ref=excluded.credential_secret_ref,base_url=excluded.base_url,
    capabilities=excluded.capabilities,non_secret_configuration=excluded.non_secret_configuration,updated_at=now()
  returning id into connector_id;
  perform public._append_fiscal_event(target_company_id,'fiscal_setting_changed','platform_connector',connector_id,clock_timestamp(),
    jsonb_build_object('connector_code','SUPERPDP','provider','SUPER PDP','environment','sandbox',
      'external_company_id',target_external_company->'id','production_enabled',false),'edge_function',
    jsonb_build_object('claim','external_sandbox_connection_tested'));
  return connector_id;
end
$$;
revoke all on function public.configure_superpdp_sandbox_connector(uuid,jsonb) from public,anon;
grant execute on function public.configure_superpdp_sandbox_connector(uuid,jsonb) to authenticated;

create or replace function public.record_superpdp_sandbox_test_transmission(
  target_company_id uuid,
  target_external_id text,
  target_external_invoice_id text
) returns uuid
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare connector_row public.platform_connectors%rowtype; transmission_id uuid; digest text;
begin
  if not public.has_company_permission(target_company_id,'electronic_invoice_manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if nullif(trim(target_external_id),'') is null then raise exception 'external_id_required'; end if;
  select * into connector_row from public.platform_connectors
  where company_id=target_company_id and connector_code='SUPERPDP' and environment='sandbox'
  order by updated_at desc limit 1;
  if connector_row.id is null then raise exception 'superpdp_connector_not_configured'; end if;
  digest:=encode(extensions.digest(convert_to(target_external_id||':'||coalesce(target_external_invoice_id,''),'UTF8'),'sha256'),'hex');
  insert into public.platform_transmissions(
    company_id,connector_id,operation,idempotency_key,status,is_simulation,attempt_count,
    external_transmission_id,external_status,request_hash,response_hash,created_by,completed_at,metadata
  ) values(
    target_company_id,connector_row.id,'send_invoice',trim(target_external_id),'succeeded',false,1,
    nullif(trim(target_external_invoice_id),''),'sandbox_queued',digest,digest,auth.uid(),clock_timestamp(),
    jsonb_build_object('provider','SUPER PDP','environment','sandbox','generated_test_invoice',true,
      'sent_to_production',false,'external_id',trim(target_external_id))
  )
  on conflict(company_id,connector_id,idempotency_key) do update set updated_at=now()
  returning id into transmission_id;
  insert into public.platform_transmission_events(
    company_id,transmission_id,event_sequence,event_type,status,source,payload_hash,payload,created_by
  ) values(target_company_id,transmission_id,1,'sandbox_invoice_queued','succeeded','SUPERPDP',digest,
    jsonb_build_object('environment','sandbox','external_id',trim(target_external_id),
      'external_invoice_id',nullif(trim(target_external_invoice_id),'')),auth.uid())
  on conflict(transmission_id,event_sequence) do nothing;
  perform public._append_fiscal_event(target_company_id,'platform_simulation_completed','platform_transmission',transmission_id,
    clock_timestamp(),jsonb_build_object('provider','SUPER PDP','environment','sandbox','external_id',trim(target_external_id),
      'external_invoice_id',nullif(trim(target_external_invoice_id),''),'external_network',true,'sent_to_production',false),
    'SUPERPDP','{}'::jsonb);
  return transmission_id;
end
$$;
revoke all on function public.record_superpdp_sandbox_test_transmission(uuid,text,text) from public,anon;
grant execute on function public.record_superpdp_sandbox_test_transmission(uuid,text,text) to authenticated;

commit;
