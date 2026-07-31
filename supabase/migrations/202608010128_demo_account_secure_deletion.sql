-- Suppression définitive d'un environnement de démonstration.
-- Garde-fous : appel service_role, administrateur actif, balise demo et suspension préalable.
create or replace function public.platform_admin_delete_suspended_demo_company(
  target_company_id uuid,
  target_actor_user_id uuid,
  target_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $$
declare
  target_company public.companies%rowtype;
  target_admin public.platform_admins%rowtype;
  relation_record record;
  delete_count integer;
  rows_deleted integer;
  pass integer;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'service_role_required' using errcode='42501';
  end if;
  if nullif(trim(target_reason),'') is null then
    raise exception 'deletion_reason_required';
  end if;

  select * into target_admin
  from public.platform_admins
  where user_id=target_actor_user_id and status='active';
  if target_admin.id is null then
    raise exception 'platform_admin_required' using errcode='42501';
  end if;

  select * into target_company from public.companies where id=target_company_id for update;
  if target_company.id is null then
    raise exception 'company_not_found';
  end if;
  if not coalesce(target_company.admin_tags,'{}'::text[]) @> array['demo']::text[] then
    raise exception 'demo_company_required' using errcode='42501';
  end if;
  if target_company.platform_status <> 'suspended' then
    raise exception 'demo_company_must_be_suspended_first';
  end if;

  perform public.append_platform_admin_audit_service(
    target_actor_user_id,
    'demo_account.delete',
    'company',
    target_company_id::text,
    target_company_id,
    jsonb_build_object('name',target_company.name,'owner_user_id',target_company.owner_user_id,'platform_status',target_company.platform_status),
    jsonb_build_object('deleted',true),
    trim(target_reason)
  );

  -- Les schémas fiscaux utilisent volontairement des clés étrangères RESTRICT.
  -- Pour un environnement explicitement marqué demo, on efface les tables filles
  -- du bas vers le haut. Plusieurs passes résolvent leurs dépendances internes.
  for pass in 1..30 loop
    delete_count:=0;
    for relation_record in
      select namespace.nspname as schema_name, child.relname as table_name, attribute.attname as column_name
      from pg_constraint constraint_row
      join pg_class child on child.oid=constraint_row.conrelid
      join pg_namespace namespace on namespace.oid=child.relnamespace
      join pg_attribute attribute on attribute.attrelid=child.oid and attribute.attnum=constraint_row.conkey[1]
      where constraint_row.contype='f'
        and constraint_row.confrelid='public.companies'::regclass
        and array_length(constraint_row.conkey,1)=1
        and constraint_row.confdeltype in ('a','r')
        and namespace.nspname='public'
      order by child.relname
    loop
      begin
        execute format('delete from %I.%I where %I=$1',relation_record.schema_name,relation_record.table_name,relation_record.column_name)
          using target_company_id;
        get diagnostics rows_deleted=row_count;
        delete_count:=delete_count+rows_deleted;
      exception
        when foreign_key_violation then null;
      end;
    end loop;
    exit when delete_count=0;
  end loop;

  delete from public.companies where id=target_company_id;
  if not found then raise exception 'demo_company_delete_failed'; end if;

  return jsonb_build_object('company_id',target_company_id,'owner_user_id',target_company.owner_user_id,'deleted',true);
end $$;

revoke all on function public.platform_admin_delete_suspended_demo_company(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.platform_admin_delete_suspended_demo_company(uuid,uuid,text) to service_role;

comment on function public.platform_admin_delete_suspended_demo_company(uuid,uuid,text)
is 'Supprime définitivement une entreprise de démonstration déjà suspendue. Réservé au serveur Piloz Admin.';
