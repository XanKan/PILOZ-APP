begin;

-- La variable locale ne doit jamais porter le même nom que la colonne de la
-- contrainte d'unicité. Cette version reste identique fonctionnellement mais
-- supprime l'ambiguïté PL/pgSQL détectée par `supabase db lint`.
create or replace function public.record_superpdp_sandbox_test_transmission(
  target_company_id uuid,
  target_external_id text,
  target_external_invoice_id text
) returns uuid
language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare connector_row public.platform_connectors%rowtype; target_transmission_id uuid; digest text;
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
  returning id into target_transmission_id;
  insert into public.platform_transmission_events(
    company_id,transmission_id,event_sequence,event_type,status,source,payload_hash,payload,created_by
  ) values(target_company_id,target_transmission_id,1,'sandbox_invoice_queued','succeeded','SUPERPDP',digest,
    jsonb_build_object('environment','sandbox','external_id',trim(target_external_id),
      'external_invoice_id',nullif(trim(target_external_invoice_id),'')),auth.uid())
  on conflict on constraint platform_transmission_events_transmission_id_event_sequence_key do nothing;
  perform public._append_fiscal_event(target_company_id,'platform_simulation_completed','platform_transmission',target_transmission_id,
    clock_timestamp(),jsonb_build_object('provider','SUPER PDP','environment','sandbox','external_id',trim(target_external_id),
      'external_invoice_id',nullif(trim(target_external_invoice_id),''),'external_network',true,'sent_to_production',false),
    'SUPERPDP','{}'::jsonb);
  return target_transmission_id;
end
$$;

revoke all on function public.record_superpdp_sandbox_test_transmission(uuid,text,text) from public,anon;
grant execute on function public.record_superpdp_sandbox_test_transmission(uuid,text,text) to authenticated;

commit;
