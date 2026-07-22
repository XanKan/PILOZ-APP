-- Contrôles à exécuter après la migration 202607220043.
do $$
begin
  if not exists(select 1 from pg_class where relnamespace='public'::regnamespace and relname='platform_transmissions') then
    raise exception 'platform_transmissions_missing';
  end if;
  if has_table_privilege('authenticated','public.platform_transmissions','INSERT')
    or has_table_privilege('authenticated','public.platform_transmissions','UPDATE')
    or has_table_privilege('authenticated','public.platform_transmissions','DELETE') then
    raise exception 'direct_transmission_write_privilege_detected';
  end if;
  if has_function_privilege('authenticated','public.record_electronic_invoice_lifecycle_event(uuid,text,text,text,text,text,timestamptz)','EXECUTE') then
    raise exception 'browser_can_forge_platform_lifecycle_event';
  end if;
  if not has_function_privilege('authenticated','public.run_platform_sandbox_simulation(uuid,text,text)','EXECUTE') then
    raise exception 'sandbox_rpc_missing';
  end if;
end
$$;
