-- Restore the legacy document-template selection after the abandoned theme
-- workspace.  This migration is additive: user templates and finalized
-- documents are never deleted or rewritten.

begin;

-- The previous trigger kept an older theme_id when template_id changed.  A
-- draft could therefore be saved with two different template references.
create or replace function public._piloz_sync_document_theme()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare
  theme public.document_templates%rowtype;
  version public.document_template_versions%rowtype;
  selected_theme_id uuid;
  theme_family text;
begin
  if tg_op='UPDATE' and old.finalized_at is not null then
    if new.theme_id is distinct from old.theme_id
      or new.theme_version is distinct from old.theme_version
      or new.theme_snapshot is distinct from old.theme_snapshot then
      raise exception 'finalized_document_theme_is_immutable' using errcode='55000';
    end if;
    return new;
  end if;

  -- An explicit legacy template change is authoritative.  Keep the internal
  -- compatibility columns aligned so the saved draft and its PDF agree.
  if tg_op='UPDATE' and new.template_id is distinct from old.template_id then
    new.theme_id:=new.template_id;
    new.theme_version:=null;
    new.theme_snapshot:=null;
  elsif tg_op='UPDATE' and new.theme_id is distinct from old.theme_id then
    new.template_id:=new.theme_id;
    new.theme_version:=null;
    new.theme_snapshot:=null;
  else
    new.theme_id:=coalesce(new.theme_id,new.template_id);
    new.template_id:=coalesce(new.template_id,new.theme_id);
  end if;

  if new.theme_id is null then
    theme_family:=case when new.document_type in('quote','sales_order') then 'quote' else 'invoice' end;

    select case when theme_family='quote'
      then settings.default_quote_template_id
      else settings.default_invoice_template_id end
    into selected_theme_id
    from public.company_document_settings settings
    where settings.company_id=new.company_id;

    if selected_theme_id is not null and not exists(
      select 1 from public.document_templates candidate
      where candidate.id=selected_theme_id and candidate.company_id=new.company_id and candidate.status='active'
    ) then
      selected_theme_id:=null;
    end if;

    if selected_theme_id is null then
      select candidate.id into selected_theme_id
      from public.document_templates candidate
      where candidate.company_id=new.company_id and candidate.status='active' and not candidate.is_system
        and candidate.document_type=theme_family
      order by candidate.is_default desc,candidate.updated_at desc,candidate.created_at asc
      limit 1;
    end if;

    if selected_theme_id is null then
      select assignment.theme_id into selected_theme_id
      from public.document_theme_assignments assignment
      join public.document_templates candidate on candidate.id=assignment.theme_id and candidate.status='active'
      where assignment.company_id=new.company_id and assignment.document_type=new.document_type
      limit 1;
    end if;

    new.theme_id:=selected_theme_id;
    new.template_id:=selected_theme_id;
  end if;

  if new.theme_id is not null then
    select * into theme from public.document_templates
    where id=new.theme_id and company_id=new.company_id;
    if theme.id is null then raise exception 'theme_not_found'; end if;
    if new.finalized_at is null then new.theme_version:=theme.current_version; end if;
    if tg_op='UPDATE' and old.finalized_at is null and new.finalized_at is not null then
      select template_version.* into version
      from public.document_template_versions template_version
      where template_version.template_id=theme.id
        and template_version.version=coalesce(new.theme_version,theme.current_version);
      if version.id is null then raise exception 'theme_version_not_found' using errcode='55000'; end if;
      new.theme_version:=version.version;
      new.theme_snapshot:=jsonb_build_object(
        'theme_id',theme.id,'name',theme.name,'version',version.version,'version_id',version.id,
        'configuration',public.normalize_document_theme_configuration(version.configuration_json),
        'renderer_version',version.renderer_version,'checksum',version.configuration_checksum
      );
    end if;
  end if;
  return new;
end
$$;

-- If the short-lived system themes replaced an empty/stale company default,
-- restore the best active user-created model.
with candidate as (
  select distinct on (template.company_id)
    template.company_id,template.id
  from public.document_templates template
  where template.status='active' and not template.is_system and template.document_type='quote'
  order by template.company_id,template.is_default desc,template.updated_at desc,template.created_at asc
)
update public.company_document_settings settings
set default_quote_template_id=candidate.id,updated_at=now()
from candidate
where settings.company_id=candidate.company_id
  and (settings.default_quote_template_id is null or exists(
    select 1 from public.document_templates current
    where current.id=settings.default_quote_template_id and current.is_system
  ));

with candidate as (
  select distinct on (template.company_id)
    template.company_id,template.id
  from public.document_templates template
  where template.status='active' and not template.is_system and template.document_type='invoice'
  order by template.company_id,template.is_default desc,template.updated_at desc,template.created_at asc
)
update public.company_document_settings settings
set default_invoice_template_id=candidate.id,updated_at=now()
from candidate
where settings.company_id=candidate.company_id
  and (settings.default_invoice_template_id is null or exists(
    select 1 from public.document_templates current
    where current.id=settings.default_invoice_template_id and current.is_system
  ));

-- Keep the compatibility assignment table aligned with the settings still
-- used by the current application.
update public.document_theme_assignments assignment
set theme_id=case when assignment.document_type in('quote','sales_order')
    then settings.default_quote_template_id else settings.default_invoice_template_id end,
    updated_at=now()
from public.company_document_settings settings
where assignment.company_id=settings.company_id
  and case when assignment.document_type in('quote','sales_order')
    then settings.default_quote_template_id else settings.default_invoice_template_id end is not null
  and assignment.theme_id is distinct from case when assignment.document_type in('quote','sales_order')
    then settings.default_quote_template_id else settings.default_invoice_template_id end;

-- Repair only editable documents that accidentally received a generated
-- system theme.  Fiscal/finalized documents remain immutable.
update public.documents document
set template_id=case when document.document_type in('quote','sales_order')
      then settings.default_quote_template_id else settings.default_invoice_template_id end,
    theme_id=case when document.document_type in('quote','sales_order')
      then settings.default_quote_template_id else settings.default_invoice_template_id end,
    theme_version=null,
    theme_snapshot=null
from public.company_document_settings settings,
     public.document_templates current_template
where document.company_id=settings.company_id
  and current_template.id=coalesce(document.template_id,document.theme_id)
  and current_template.is_system
  and document.finalized_at is null
  and case when document.document_type in('quote','sales_order')
    then settings.default_quote_template_id else settings.default_invoice_template_id end is not null;

-- Repair any remaining mismatch created while the previous trigger was live.
update public.documents
set theme_id=template_id,theme_version=null,theme_snapshot=null
where finalized_at is null and template_id is not null and theme_id is distinct from template_id;

commit;
