-- Contrôles à exécuter après la migration 202607220041.
do $$
begin
  if not exists(select 1 from pg_class where relnamespace='public'::regnamespace and relname='fiscal_archives') then
    raise exception 'fiscal_archives_missing';
  end if;
  if not exists(select 1 from pg_class where relnamespace='public'::regnamespace and relname='fiscal_archive_items') then
    raise exception 'fiscal_archive_items_missing';
  end if;
  if not exists(select 1 from pg_trigger where tgname='fiscal_archives_immutable' and not tgisinternal) then
    raise exception 'fiscal_archives_immutable_trigger_missing';
  end if;
  if has_table_privilege('authenticated','public.fiscal_archives','INSERT')
    or has_table_privilege('authenticated','public.fiscal_archives','UPDATE')
    or has_table_privilege('authenticated','public.fiscal_archives','DELETE') then
    raise exception 'authenticated_archive_write_privilege_detected';
  end if;
  if has_table_privilege('authenticated','public.fiscal_archive_items','INSERT')
    or has_table_privilege('authenticated','public.fiscal_archive_items','UPDATE')
    or has_table_privilege('authenticated','public.fiscal_archive_items','DELETE') then
    raise exception 'authenticated_archive_item_write_privilege_detected';
  end if;
  if not has_function_privilege('authenticated','public.create_fiscal_archive(uuid,timestamptz,timestamptz,boolean)','EXECUTE') then
    raise exception 'archive_rpc_not_executable';
  end if;
end
$$;
