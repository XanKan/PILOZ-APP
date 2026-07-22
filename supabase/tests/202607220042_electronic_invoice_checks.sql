-- Contrôles à exécuter après la migration 202607220042.
do $$
begin
  if not exists(select 1 from pg_class where relnamespace='public'::regnamespace and relname='electronic_invoice_records') then
    raise exception 'electronic_invoice_records_missing';
  end if;
  if exists(select 1 from public.electronic_format_profiles) then
    raise exception 'unexpected_unverified_electronic_profile_seed';
  end if;
  if has_table_privilege('authenticated','public.electronic_invoice_records','INSERT')
    or has_table_privilege('authenticated','public.electronic_invoice_records','UPDATE')
    or has_table_privilege('authenticated','public.electronic_invoice_records','DELETE') then
    raise exception 'direct_electronic_record_write_privilege_detected';
  end if;
  if not has_function_privilege('authenticated','public.create_canonical_invoice_record(uuid)','EXECUTE') then
    raise exception 'canonical_invoice_rpc_missing';
  end if;
end
$$;
