begin;

-- Document themes build on the existing versioned template identities. This is
-- deliberately additive: every existing template keeps its id and every
-- historical document/snapshot keeps its current foreign keys and PDF.

alter table public.document_templates
  add column if not exists source_theme_id uuid references public.document_templates(id) on delete set null,
  add column if not exists is_system boolean not null default false,
  add column if not exists supported_document_types jsonb not null default '[]'::jsonb,
  add column if not exists thumbnail_storage_path text,
  add column if not exists thumbnail_config jsonb not null default '{}'::jsonb,
  add column if not exists renderer_version text not null default 'theme-renderer-v1',
  add column if not exists archived_at timestamptz;

update public.document_templates
set supported_document_types=jsonb_build_array(document_type)
where jsonb_typeof(supported_document_types)<>'array' or jsonb_array_length(supported_document_types)=0;

alter table public.document_templates drop constraint if exists document_templates_supported_types_array;
alter table public.document_templates add constraint document_templates_supported_types_array
  check(jsonb_typeof(supported_document_types)='array') not valid;
alter table public.document_templates validate constraint document_templates_supported_types_array;

alter table public.document_template_versions
  add column if not exists configuration_json jsonb not null default '{}'::jsonb,
  add column if not exists renderer_version text not null default 'theme-renderer-v1',
  add column if not exists configuration_checksum text,
  add column if not exists parent_version_id uuid references public.document_template_versions(id) on delete set null;

alter table public.documents
  add column if not exists theme_id uuid references public.document_templates(id) on delete restrict,
  add column if not exists theme_version integer,
  add column if not exists theme_snapshot jsonb;

create table if not exists public.document_theme_assignments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  document_type text not null,
  theme_id uuid not null references public.document_templates(id) on delete restrict,
  created_by uuid not null default auth.uid(),
  updated_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,document_type)
);

create table if not exists public.document_theme_assets(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  theme_id uuid references public.document_templates(id) on delete cascade,
  asset_type text not null check(asset_type in('logo','footer_logo','decoration','thumbnail')),
  name text not null,
  storage_bucket text not null default 'company-assets' check(storage_bucket='company-assets'),
  storage_path text not null,
  mime_type text not null check(mime_type in('image/png','image/jpeg','image/webp','image/svg+xml')),
  size_bytes bigint not null check(size_bytes between 1 and 5242880),
  width integer,
  height integer,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(theme_id,storage_path)
);

create table if not exists public.document_theme_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  theme_id uuid not null references public.document_templates(id) on delete cascade,
  label text not null,
  url text not null check(url ~* '^https?://'),
  display_text text,
  placement text not null default 'footer' check(placement in('header','body','footer')),
  document_types jsonb not null default '[]'::jsonb,
  open_external boolean not null default true,
  icon text,
  position integer not null default 1 check(position>0),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.document_theme_footer_logos(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  theme_id uuid not null references public.document_templates(id) on delete cascade,
  asset_id uuid not null references public.document_theme_assets(id) on delete restrict,
  name text not null,
  position integer not null default 1 check(position>0),
  width integer not null default 64 check(width between 24 and 180),
  visible boolean not null default true,
  document_types jsonb not null default '[]'::jsonb,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(theme_id,asset_id)
);

create table if not exists public.document_theme_usage(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  theme_id uuid not null references public.document_templates(id) on delete restrict,
  theme_version integer not null check(theme_version>0),
  document_id uuid not null references public.documents(id) on delete restrict,
  snapshot_id uuid references public.document_snapshots(id) on delete restrict,
  configuration_checksum text,
  frozen_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique(document_id)
);

create table if not exists public.document_theme_user_preferences(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null,
  help_dismissed boolean not null default false,
  editor_info_dismissed boolean not null default false,
  last_theme_id uuid references public.document_templates(id) on delete set null,
  last_section text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,user_id)
);

create index if not exists document_templates_theme_status_idx
  on public.document_templates(company_id,status,updated_at desc);
create index if not exists document_theme_versions_theme_idx
  on public.document_template_versions(company_id,template_id,version desc);
create index if not exists document_theme_assets_theme_idx
  on public.document_theme_assets(company_id,theme_id,asset_type,created_at desc);
create index if not exists document_theme_links_theme_idx
  on public.document_theme_links(company_id,theme_id,position);
create index if not exists document_theme_usage_theme_idx
  on public.document_theme_usage(company_id,theme_id,theme_version);
create index if not exists documents_theme_idx on public.documents(company_id,theme_id);

do $theme_updated_at$
declare table_name text;
begin
  foreach table_name in array array['document_theme_assignments','document_theme_links','document_theme_footer_logos','document_theme_user_preferences'] loop
    execute format('drop trigger if exists %I on public.%I',table_name||'_set_updated_at',table_name);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_current_timestamp_updated_at()',table_name||'_set_updated_at',table_name);
  end loop;
end
$theme_updated_at$;

create or replace function public._piloz_document_theme_default_configuration(target_structure text default 'classic-balanced')
returns jsonb language sql immutable set search_path=public,pg_temp as $$
  select jsonb_build_object(
    'schema_version',1,
    'renderer_version','theme-renderer-v1',
    'structure',jsonb_build_object('key',case when target_structure in(
      'classic-balanced','compact-header','split-addresses','boxed-client','editorial','modern-color'
    ) then target_structure else 'classic-balanced' end),
    'logo',jsonb_build_object('enabled',true,'asset_id',null,'width',128,'alignment','left','preserve_ratio',true),
    'colors',jsonb_build_object(
      'primary','#11BFAE','secondary','#13294B','background','#FFFFFF','text','#172038',
      'muted','#64748B','border','#DCE4EE'
    ),
    'typography',jsonb_build_object(
      'title',jsonb_build_object('family','Helvetica','size','normal'),
      'content',jsonb_build_object('family','Helvetica','size','normal'),
      'table',jsonb_build_object('family','Helvetica','size','normal')
    ),
    'table',jsonb_build_object(
      'striped',false,'borders',true,'colored_header',true,'radius',2,
      'columns',jsonb_build_array(
        jsonb_build_object('key','number','label','#','visible',true,'locked',false,'position',1),
        jsonb_build_object('key','description','label','Désignation et description','visible',true,'locked',true,'position',2),
        jsonb_build_object('key','unit','label','Unité','visible',true,'locked',false,'position',3),
        jsonb_build_object('key','quantity','label','Quantité','visible',true,'locked',false,'position',4),
        jsonb_build_object('key','unit_price','label','Prix unitaire HT','visible',true,'locked',false,'position',5),
        jsonb_build_object('key','discount','label','Remise','visible',false,'locked',false,'position',6),
        jsonb_build_object('key','tax_rate','label','TVA','visible',false,'locked',false,'position',7),
        jsonb_build_object('key','total_excl_tax','label','Montant HT','visible',true,'locked',false,'position',8),
        jsonb_build_object('key','total_incl_tax','label','Montant TTC','visible',false,'locked',false,'position',9)
      )
    ),
    'decoration',jsonb_build_object('kind','none','asset_id',null,'opacity',0.12,'position','all','repeat',false),
    'footer',jsonb_build_object(
      'show_piloz_brand',false,'free_text','','show_legal',true,'show_contact',true,
      'show_bank_details',true,'show_page_number',true,'logo_ids','[]'::jsonb
    ),
    'spacing',jsonb_build_object('top',36,'bottom',48,'left',36,'right',36,'link_vertical',false,'link_horizontal',false),
    'links','[]'::jsonb,
    'assignments','[]'::jsonb
  )
$$;

create or replace function public.normalize_document_theme_configuration(target_configuration jsonb)
returns jsonb language plpgsql immutable set search_path=public,pg_temp as $$
declare
  incoming jsonb:=case when jsonb_typeof(target_configuration)='object' then target_configuration else '{}'::jsonb end;
  result jsonb:=public._piloz_document_theme_default_configuration(coalesce(target_configuration->'structure'->>'key','classic-balanced'));
  section text; link_row jsonb; safe_links jsonb:='[]'::jsonb;
begin
  foreach section in array array['structure','logo','colors','typography','table','decoration','footer','spacing'] loop
    if jsonb_typeof(incoming->section)='object' then
      result:=jsonb_set(result,array[section],(result->section)||(incoming->section),true);
    end if;
  end loop;
  if jsonb_typeof(incoming->'links')='array' then
    for link_row in select value from jsonb_array_elements(incoming->'links') limit 12 loop
      if coalesce(link_row->>'url','') ~* '^https?://[a-z0-9]' then safe_links:=safe_links||jsonb_build_array(link_row); end if;
    end loop;
    result:=jsonb_set(result,'{links}',safe_links,true);
  end if;
  if jsonb_typeof(incoming->'assignments')='array' then result:=jsonb_set(result,'{assignments}',incoming->'assignments',true); end if;
  result:=jsonb_set(result,'{schema_version}','1'::jsonb,true);
  result:=jsonb_set(result,'{renderer_version}',to_jsonb('theme-renderer-v1'::text),true);
  result:=result#-'{logo,signed_url}'#-'{decoration,signed_url}';
  return result;
end
$$;

update public.document_template_versions version
set configuration_json=public.normalize_document_theme_configuration(jsonb_build_object(
  'structure',jsonb_build_object('key',case version.layout_key
    when 'modern' then 'modern-color' when 'compact' then 'compact-header' else 'classic-balanced' end),
  'logo',coalesce(version.logo_settings,'{}'::jsonb),
  'colors',jsonb_build_object(
    'primary',coalesce(version.color_settings->>'primary','#11BFAE'),
    'secondary',coalesce(version.color_settings->>'secondary','#13294B'),
    'background',coalesce(version.color_settings->>'background','#FFFFFF'),
    'text',coalesce(version.color_settings->>'text','#172038'),
    'muted',coalesce(version.color_settings->>'muted','#64748B'),
    'border',coalesce(version.color_settings->>'border','#DCE4EE')
  ),
  'table',jsonb_build_object('columns',case when jsonb_typeof(version.visible_columns)='array' then version.visible_columns else '[]'::jsonb end),
  'footer',jsonb_build_object('show_bank_details',version.bank_details_visibility<>'hidden')
))
where configuration_json='{}'::jsonb;

update public.document_template_versions
set configuration_checksum=encode(extensions.digest(convert_to(configuration_json::text,'UTF8'),'sha256'),'hex')
where configuration_checksum is null;

update public.document_templates theme
set thumbnail_config=version.configuration_json,
    renderer_version=coalesce(version.renderer_version,'theme-renderer-v1')
from public.document_template_versions version
where version.template_id=theme.id and version.version=theme.current_version
  and theme.thumbnail_config='{}'::jsonb;

-- Existing mutable drafts acquire the compatibility theme reference. Finalized
-- documents are intentionally left untouched; their immutable snapshots remain
-- the sole historical source of truth.
update public.documents document
set theme_id=document.template_id,theme_version=template.current_version
from public.document_templates template
where document.finalized_at is null and document.template_id=template.id and document.theme_id is null;

create or replace function public._piloz_can_manage_document_themes(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.company_members member
    where member.company_id=target_company_id and member.user_id=auth.uid()
      and (member.role in('owner','admin') or coalesce((member.permissions->>'manage_document_themes')::boolean,false))
  )
$$;

create or replace function public._piloz_document_theme_unique_name(target_company_id uuid,target_base_name text)
returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare base_name text:=coalesce(nullif(trim(target_base_name),''),'Nouveau thème'); candidate text; suffix integer:=1;
begin
  candidate:=base_name;
  while exists(select 1 from public.document_templates where company_id=target_company_id and lower(name)=lower(candidate)) loop
    suffix:=suffix+1; candidate:=base_name||' ('||suffix||')';
  end loop;
  return candidate;
end
$$;

create or replace function public.create_document_theme(target_company_id uuid,target_source_theme_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare source_theme public.document_templates%rowtype; source_version public.document_template_versions%rowtype;
  new_theme_id uuid; new_version_id uuid; new_name text; config jsonb; actor uuid:=auth.uid();
  source_asset public.document_theme_assets%rowtype; copied_asset_id uuid; copied_footer_id uuid;
  copied_footer_ids jsonb:='[]'::jsonb;
begin
  if actor is null or not public._piloz_can_manage_document_themes(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if target_source_theme_id is not null then
    select * into source_theme from public.document_templates
    where id=target_source_theme_id and company_id=target_company_id and status='active';
    if source_theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
    select * into source_version from public.document_template_versions
    where template_id=source_theme.id and version=source_theme.current_version;
    config:=public.normalize_document_theme_configuration(source_version.configuration_json);
    new_name:=public._piloz_document_theme_unique_name(target_company_id,source_theme.name||' — copie');
  else
    config:=public._piloz_document_theme_default_configuration('classic-balanced');
    new_name:=public._piloz_document_theme_unique_name(target_company_id,'Nouveau thème');
  end if;
  insert into public.document_templates(
    company_id,name,document_type,language,status,is_default,current_version,source_theme_id,is_system,
    supported_document_types,renderer_version,thumbnail_config,created_by,updated_by
  ) values(
    target_company_id,new_name,'quote','fr','active',false,1,target_source_theme_id,false,
    '["quote","invoice","sales_order","credit_note","deposit_invoice","balance_invoice","progress_invoice","purchase_order"]'::jsonb,
    'theme-renderer-v1',config,actor,actor
  ) returning id into new_theme_id;
  if target_source_theme_id is not null then
    for source_asset in
      select * from public.document_theme_assets
      where theme_id=target_source_theme_id and company_id=target_company_id
      order by created_at,id
    loop
      insert into public.document_theme_assets(company_id,theme_id,asset_type,name,storage_bucket,storage_path,mime_type,size_bytes,width,height,metadata,created_by)
      values(target_company_id,new_theme_id,source_asset.asset_type,source_asset.name,source_asset.storage_bucket,
        source_asset.storage_path,source_asset.mime_type,source_asset.size_bytes,source_asset.width,source_asset.height,
        source_asset.metadata,actor)
      on conflict(theme_id,storage_path) do update set name=excluded.name
      returning id into copied_asset_id;
      if source_asset.id=nullif(config->'logo'->>'asset_id','')::uuid then
        config:=jsonb_set(config,'{logo,asset_id}',to_jsonb(copied_asset_id::text),true);
      end if;
      if source_asset.id=nullif(config->'decoration'->>'asset_id','')::uuid then
        config:=jsonb_set(config,'{decoration,asset_id}',to_jsonb(copied_asset_id::text),true);
      end if;
      copied_footer_id:=null;
      insert into public.document_theme_footer_logos(company_id,theme_id,asset_id,name,position,width,visible,document_types,created_by)
      select target_company_id,new_theme_id,copied_asset_id,footer.name,footer.position,footer.width,footer.visible,footer.document_types,actor
      from public.document_theme_footer_logos footer
      where footer.theme_id=target_source_theme_id and footer.asset_id=source_asset.id
      returning id into copied_footer_id;
      if copied_footer_id is not null then
        copied_footer_ids:=copied_footer_ids||to_jsonb(copied_footer_id::text);
      end if;
    end loop;
    config:=jsonb_set(config,'{footer,logo_ids}',copied_footer_ids,true);
    insert into public.document_theme_links(company_id,theme_id,label,url,display_text,placement,document_types,open_external,icon,position,created_by)
    select company_id,new_theme_id,label,url,display_text,placement,document_types,open_external,icon,position,actor
    from public.document_theme_links where theme_id=target_source_theme_id and company_id=target_company_id;
  end if;
  update public.document_templates set thumbnail_config=config where id=new_theme_id;
  insert into public.document_template_versions(
    company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,
    logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,document_title,free_field,
    client_profile,issuer_profile,payment_methods,configuration_json,renderer_version,configuration_checksum,created_by
  ) values(
    target_company_id,new_theme_id,1,'{}'::jsonb,'','','Création du thème',
    case config->'structure'->>'key' when 'modern-color' then 'modern' when 'compact-header' then 'compact' else 'classic' end,
    config->'colors',config->'logo',config->'table'->'columns','[]'::jsonb,null,
    case when coalesce((config->'footer'->>'show_bank_details')::boolean,true) then 'footer' else 'hidden' end,
    'Document',null,'{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,
    config,'theme-renderer-v1',encode(extensions.digest(convert_to(config::text,'UTF8'),'sha256'),'hex'),actor
  ) returning id into new_version_id;
  return jsonb_build_object('theme_id',new_theme_id,'version_id',new_version_id,'version',1,'name',new_name);
end
$$;

create or replace function public.assign_document_theme(target_theme_id uuid,target_document_type text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare theme public.document_templates%rowtype; actor uuid:=auth.uid(); allowed_types text[]:=array[
  'quote','invoice','sales_order','credit_note','deposit_invoice','balance_invoice','progress_invoice','purchase_order'
];
begin
  select * into theme from public.document_templates where id=target_theme_id and status='active';
  if theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
  if actor is null or not public._piloz_can_manage_document_themes(theme.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if not target_document_type=any(allowed_types) then raise exception 'unsupported_document_type'; end if;
  if not theme.supported_document_types ? target_document_type then
    update public.document_templates set supported_document_types=supported_document_types||to_jsonb(target_document_type),updated_at=now() where id=theme.id;
  end if;
  insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
  values(theme.company_id,target_document_type,theme.id,actor,actor)
  on conflict(company_id,document_type) do update set theme_id=excluded.theme_id,updated_by=actor,updated_at=now();
  if target_document_type='quote' then
    update public.document_templates set is_default=false,updated_at=now()
    where company_id=theme.company_id and document_type='quote' and language='fr' and is_default;
    update public.document_templates set is_default=true,updated_at=now() where id=theme.id;
    update public.company_document_settings set default_quote_template_id=theme.id,updated_at=now() where company_id=theme.company_id;
  elsif target_document_type='invoice' then
    update public.company_document_settings set default_invoice_template_id=theme.id,updated_at=now() where company_id=theme.company_id;
  end if;
  return jsonb_build_object('theme_id',theme.id,'document_type',target_document_type);
end
$$;

create or replace function public.save_document_theme(
  target_theme_id uuid,target_name text,target_configuration jsonb,target_assignments jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare theme public.document_templates%rowtype; previous public.document_template_versions%rowtype;
  config jsonb; next_version integer; result_version_id uuid; actor uuid:=auth.uid(); doc_type text; margin_value numeric; fallback_theme_id uuid;
begin
  select * into theme from public.document_templates where id=target_theme_id for update;
  if theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
  if actor is null or not public._piloz_can_manage_document_themes(theme.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if theme.status='archived' then raise exception 'theme_archived'; end if;
  if nullif(trim(target_name),'') is null or length(trim(target_name))>100 then raise exception 'invalid_theme_name'; end if;
  if exists(select 1 from public.document_templates other where other.company_id=theme.company_id and other.id<>theme.id and lower(other.name)=lower(trim(target_name))) then raise exception 'theme_name_already_exists'; end if;
  config:=public.normalize_document_theme_configuration(target_configuration);
  if config::text ~* '(javascript:|data:)' then raise exception 'dangerous_theme_url'; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(config->'links','[]'::jsonb)) link where coalesce(link->>'url','') !~* '^https?://') then raise exception 'invalid_theme_url'; end if;
  foreach doc_type in array array['primary','secondary','background','text','muted','border'] loop
    if coalesce(config->'colors'->>doc_type,'') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'invalid_theme_color:%',doc_type; end if;
  end loop;
  foreach doc_type in array array['top','bottom','left','right'] loop
    margin_value:=coalesce((config->'spacing'->>doc_type)::numeric,0);
    if margin_value<12 or margin_value>120 then raise exception 'invalid_theme_spacing:%',doc_type; end if;
  end loop;
  if not exists(select 1 from jsonb_array_elements(config->'table'->'columns') col where col->>'key'='description' and coalesce((col->>'visible')::boolean,false)) then raise exception 'description_column_required'; end if;
  select * into previous from public.document_template_versions where template_id=theme.id and version=theme.current_version;
  next_version:=theme.current_version+1;
  update public.document_templates set name=trim(target_name),current_version=next_version,updated_by=actor,
    renderer_version='theme-renderer-v1',thumbnail_config=config,updated_at=now() where id=theme.id;
  insert into public.document_template_versions(
    company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,
    logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,document_title,free_field,
    client_profile,issuer_profile,payment_methods,configuration_json,renderer_version,configuration_checksum,parent_version_id,created_by
  ) values(
    theme.company_id,theme.id,next_version,coalesce(previous.visual_schema,'{}'::jsonb),coalesce(previous.html,''),coalesce(previous.css,''),
    'Enregistrement depuis l’éditeur de thèmes',
    case config->'structure'->>'key' when 'modern-color' then 'modern' when 'compact-header' then 'compact' else 'classic' end,
    config->'colors',config->'logo',config->'table'->'columns',coalesce(previous.header_fields,'[]'::jsonb),previous.footer_id,
    case when coalesce((config->'footer'->>'show_bank_details')::boolean,true) then 'footer' else 'hidden' end,
    coalesce(previous.document_title,'Document'),previous.free_field,coalesce(previous.client_profile,'{"show_email":true,"show_phone":true}'::jsonb),
    coalesce(previous.issuer_profile,'{}'::jsonb),coalesce(previous.payment_methods,'["bank_transfer"]'::jsonb),config,'theme-renderer-v1',
    encode(extensions.digest(convert_to(config::text,'UTF8'),'sha256'),'hex'),previous.id,actor
  ) returning id into result_version_id;
  if jsonb_typeof(target_assignments)='array' then
    for doc_type in select assignment.document_type from public.document_theme_assignments assignment
      where assignment.company_id=theme.company_id and assignment.theme_id=theme.id
        and not (target_assignments ? assignment.document_type)
    loop
      select candidate.id into fallback_theme_id from public.document_templates candidate
      where candidate.company_id=theme.company_id and candidate.id<>theme.id and candidate.status='active'
        and (candidate.supported_document_types ? doc_type or candidate.document_type=doc_type)
      order by candidate.is_system desc,candidate.created_at asc limit 1;
      if fallback_theme_id is not null then perform public.assign_document_theme(fallback_theme_id,doc_type); end if;
    end loop;
    for doc_type in select jsonb_array_elements_text(target_assignments) loop
      perform public.assign_document_theme(theme.id,doc_type);
    end loop;
  end if;
  return jsonb_build_object('theme_id',theme.id,'version_id',result_version_id,'version',next_version,'checksum',
    encode(extensions.digest(convert_to(config::text,'UTF8'),'sha256'),'hex'));
end
$$;

create or replace function public.rename_document_theme(target_theme_id uuid,target_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare theme public.document_templates%rowtype; actor uuid:=auth.uid();
begin
  select * into theme from public.document_templates where id=target_theme_id for update;
  if theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
  if actor is null or not public._piloz_can_manage_document_themes(theme.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(target_name),'') is null or length(trim(target_name))>100 then raise exception 'invalid_theme_name'; end if;
  if exists(select 1 from public.document_templates other where other.company_id=theme.company_id and other.id<>theme.id and lower(other.name)=lower(trim(target_name))) then raise exception 'theme_name_already_exists'; end if;
  update public.document_templates set name=trim(target_name),updated_by=actor,updated_at=now() where id=theme.id;
  return jsonb_build_object('theme_id',theme.id,'name',trim(target_name));
end
$$;

create or replace function public.archive_document_theme(target_theme_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare theme public.document_templates%rowtype; actor uuid:=auth.uid();
begin
  select * into theme from public.document_templates where id=target_theme_id for update;
  if theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
  if actor is null or not public._piloz_can_manage_document_themes(theme.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  if exists(select 1 from public.document_theme_assignments where theme_id=theme.id) then raise exception 'theme_is_assigned'; end if;
  update public.document_templates set status='archived',is_default=false,archived_at=now(),updated_by=actor,updated_at=now() where id=theme.id;
  return jsonb_build_object('theme_id',theme.id,'status','archived');
end
$$;

create or replace function public.delete_document_theme(target_theme_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare theme public.document_templates%rowtype; actor uuid:=auth.uid(); active_count integer;
begin
  select * into theme from public.document_templates where id=target_theme_id for update;
  if theme.id is null then raise exception 'theme_not_found' using errcode='P0002'; end if;
  if actor is null or not public._piloz_can_manage_document_themes(theme.company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select count(*) into active_count from public.document_templates where company_id=theme.company_id and status='active';
  if theme.is_system and active_count<=1 then raise exception 'last_system_theme'; end if;
  if exists(select 1 from public.document_theme_assignments where theme_id=theme.id)
    or exists(select 1 from public.documents where coalesce(theme_id,template_id)=theme.id)
    or exists(select 1 from public.document_theme_usage where theme_id=theme.id)
  then raise exception 'theme_is_used'; end if;
  delete from public.document_templates where id=theme.id;
  return jsonb_build_object('theme_id',theme.id,'deleted',true);
end
$$;

create or replace function public._piloz_sync_document_theme()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare theme public.document_templates%rowtype; version public.document_template_versions%rowtype; selected_theme_id uuid; theme_family text;
begin
  if tg_op='UPDATE' and old.finalized_at is not null then
    if new.theme_id is distinct from old.theme_id or new.theme_version is distinct from old.theme_version or new.theme_snapshot is distinct from old.theme_snapshot then
      raise exception 'finalized_document_theme_is_immutable' using errcode='55000';
    end if;
    return new;
  end if;
  new.theme_id:=coalesce(new.theme_id,new.template_id);
  new.template_id:=coalesce(new.template_id,new.theme_id);
  if new.theme_id is null then
    theme_family:=case
      when new.document_type in('quote','sales_order','credit_note','deposit_invoice','balance_invoice','progress_invoice','purchase_order') then new.document_type
      else 'invoice' end;
    select assignment.theme_id into selected_theme_id
    from public.document_theme_assignments assignment
    join public.document_templates candidate on candidate.id=assignment.theme_id and candidate.status='active'
    where assignment.company_id=new.company_id and assignment.document_type=theme_family limit 1;
    if selected_theme_id is null then
      select candidate.id into selected_theme_id from public.document_templates candidate
      where candidate.company_id=new.company_id and candidate.status='active'
        and candidate.supported_document_types ? theme_family
      order by candidate.is_default desc,candidate.is_system desc,candidate.created_at limit 1;
    end if;
    new.theme_id:=selected_theme_id; new.template_id:=selected_theme_id;
  end if;
  if new.theme_id is not null then
    select * into theme from public.document_templates where id=new.theme_id and company_id=new.company_id;
    if theme.id is null then raise exception 'theme_not_found'; end if;
    if new.finalized_at is null then new.theme_version:=theme.current_version; end if;
    if tg_op='UPDATE' and old.finalized_at is null and new.finalized_at is not null then
      select template_version.* into version from public.document_template_versions template_version
      where template_version.template_id=theme.id and template_version.version=coalesce(new.theme_version,theme.current_version);
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

drop trigger if exists documents_sync_theme on public.documents;
create trigger documents_sync_theme before insert or update of template_id,theme_id,theme_version,theme_snapshot,finalized_at
on public.documents for each row execute function public._piloz_sync_document_theme();

create or replace function public._piloz_record_document_theme_usage()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.finalized_at is null and new.finalized_at is not null and new.theme_id is not null then
    insert into public.document_theme_usage(
      company_id,theme_id,theme_version,document_id,configuration_checksum,frozen_at,created_by
    ) values(
      new.company_id,new.theme_id,new.theme_version,new.id,new.theme_snapshot->>'checksum',new.finalized_at,coalesce(new.finalized_by,new.created_by)
    ) on conflict(document_id) do nothing;
  end if;
  return new;
end
$$;

drop trigger if exists documents_record_theme_usage on public.documents;
create trigger documents_record_theme_usage after update of finalized_at on public.documents
for each row execute function public._piloz_record_document_theme_usage();

-- Freeze the exact selected theme version (not the later current version) in
-- the existing fiscal snapshot. Theme assets are copied by storage path and
-- metadata, so replacing a company's current logo cannot alter an old PDF.
create or replace function public._piloz_create_document_snapshot(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; issuer jsonb; document_settings jsonb; customer jsonb; frozen_logo jsonb;
  public_lines jsonb; internal_lines jsonb; template_payload jsonb; theme_config jsonb; legacy_logo_settings jsonb;
  footer_row jsonb; footer_logos jsonb; footer_id_value uuid; logo_asset_id uuid; logo_variant text;
  public_snapshot jsonb; internal_snapshot jsonb; snapshot_hash text; next_version integer; result_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or (doc.finalized_at is null and doc.document_type<>'quote') then raise exception 'document_not_finalized'; end if;
  select to_jsonb(s) into issuer from public.company_settings s where s.company_id=doc.company_id;
  select to_jsonb(s) into document_settings from public.company_document_settings s where s.company_id=doc.company_id;
  select to_jsonb(c) into customer from public.clients c where c.id=doc.client_id and c.company_id=doc.company_id;
  select jsonb_build_object('template',to_jsonb(t),'version',to_jsonb(tv)) into template_payload
  from public.document_templates t
  left join public.document_template_versions tv on tv.template_id=t.id
    and tv.version=coalesce(doc.theme_version,t.current_version)
  where t.id=coalesce(doc.theme_id,doc.template_id) and t.company_id=doc.company_id;
  if template_payload is null then
    theme_config:=public._piloz_document_theme_default_configuration('classic-balanced');
    template_payload:=jsonb_build_object('template','{}'::jsonb,'version',jsonb_build_object(
      'configuration_json',theme_config,'renderer_version','theme-renderer-v1'),'configuration',theme_config);
  else
    theme_config:=public.normalize_document_theme_configuration(template_payload->'version'->'configuration_json');
    template_payload:=jsonb_set(template_payload,'{configuration}',theme_config,true);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',footer.id,'name',footer.name,'position',footer.position,'width',footer.width,
    'document_types',footer.document_types,'storage_path',asset.storage_path,'mime_type',asset.mime_type,'size_bytes',asset.size_bytes
  ) order by footer.position),'[]'::jsonb) into footer_logos
  from public.document_theme_footer_logos footer
  join public.document_theme_assets asset on asset.id=footer.asset_id and asset.company_id=footer.company_id
  where footer.theme_id=coalesce(doc.theme_id,doc.template_id) and footer.company_id=doc.company_id and footer.visible
    and (jsonb_array_length(footer.document_types)=0 or footer.document_types ? doc.document_type
      or (doc.document_type<>'quote' and footer.document_types ? 'invoice'));
  template_payload:=jsonb_set(template_payload,'{theme_footer_logos}',coalesce(footer_logos,'[]'::jsonb),true);
  footer_id_value:=nullif(template_payload->'version'->>'footer_id','')::uuid;
  if footer_id_value is not null then
    select to_jsonb(f) into footer_row from public.document_footers f where f.id=footer_id_value and f.company_id=doc.company_id;
    if footer_row is not null then template_payload:=jsonb_set(template_payload,'{footer}',footer_row,true); end if;
  end if;
  logo_asset_id:=nullif(theme_config->'logo'->>'asset_id','')::uuid;
  if coalesce((theme_config->'logo'->>'enabled')::boolean,true) and logo_asset_id is not null then
    select jsonb_build_object('storage_path',asset.storage_path,'mime_type',asset.mime_type,'size_bytes',asset.size_bytes,
      'width',asset.width,'height',asset.height,'asset_id',asset.id,'source','document_theme') into frozen_logo
    from public.document_theme_assets asset where asset.id=logo_asset_id and asset.company_id=doc.company_id
      and asset.theme_id=coalesce(doc.theme_id,doc.template_id) and asset.asset_type='logo';
  end if;
  if frozen_logo is null then
    legacy_logo_settings:=coalesce(template_payload->'version'->'logo_settings','{}'::jsonb);
    logo_variant:=case when coalesce((legacy_logo_settings->>'use_alternate')::boolean,false) then 'dark' else 'light' end;
    if coalesce((legacy_logo_settings->>'show')::boolean,true) then
      select jsonb_build_object('storage_path',logo.storage_path,'mime_type',logo.mime_type,'size_bytes',logo.size_bytes,
        'width',logo.width,'height',logo.height,'variant',logo.variant,'source','company_logo') into frozen_logo
      from public.company_logos logo where logo.company_id=doc.company_id and logo.variant=logo_variant and logo.is_active
      order by logo.created_at desc limit 1;
      if frozen_logo is null and logo_variant='dark' then
        select jsonb_build_object('storage_path',logo.storage_path,'mime_type',logo.mime_type,'size_bytes',logo.size_bytes,
          'width',logo.width,'height',logo.height,'variant',logo.variant,'source','company_logo') into frozen_logo
        from public.company_logos logo where logo.company_id=doc.company_id and logo.variant='light' and logo.is_active
        order by logo.created_at desc limit 1;
      end if;
    end if;
  end if;
  select coalesce(jsonb_agg(to_jsonb(l)-array['unit_cost_snapshot','line_metadata','created_by','created_at','updated_at']::text[] order by l.position),'[]'::jsonb),
    coalesce(jsonb_agg(to_jsonb(l) order by l.position),'[]'::jsonb)
  into public_lines,internal_lines from public.document_lines l where l.document_id=doc.id;
  public_snapshot:=jsonb_build_object('schema_version',3,'captured_at',now(),
    'document',to_jsonb(doc)-array['total_cost','internal_notes','final_pdf_path','final_pdf_sha256']::text[],
    'lines',public_lines,'issuer',coalesce(issuer,'{}'::jsonb),'document_settings',coalesce(document_settings,'{}'::jsonb)-'mandate_reference',
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(frozen_logo,'{}'::jsonb),'template',template_payload);
  internal_snapshot:=jsonb_build_object('schema_version',3,'captured_at',now(),'document',to_jsonb(doc),'lines',internal_lines,
    'issuer',coalesce(issuer,'{}'::jsonb),'document_settings',coalesce(document_settings,'{}'::jsonb),
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(frozen_logo,'{}'::jsonb),'template',template_payload);
  snapshot_hash:=encode(extensions.digest(convert_to(public_snapshot::text,'UTF8'),'sha256'),'hex');
  select coalesce(max(snapshot_version),0)+1 into next_version from public.document_snapshots where document_id=doc.id;
  insert into public.document_snapshots(company_id,document_id,snapshot_version,snapshot_kind,public_payload,internal_payload,payload_hash,pdf_status,created_by)
  values(doc.company_id,doc.id,next_version,'finalization',public_snapshot,internal_snapshot,snapshot_hash,'pending',coalesce(auth.uid(),doc.created_by))
  returning id into result_id;
  update public.document_theme_usage set snapshot_id=result_id where document_id=doc.id and snapshot_id is null;
  return result_id;
end
$$;
revoke all on function public._piloz_create_document_snapshot(uuid) from public,anon,authenticated,service_role;

-- Seed three genuinely different system themes per company without replacing
-- or archiving any user-created model.
do $seed_themes$
declare company_row record; theme_name text; structure_key text; created_theme_id uuid; config jsonb;
begin
  for company_row in select id,owner_user_id from public.companies loop
    foreach theme_name in array array['Classique','Moderne','Compact'] loop
      if not exists(select 1 from public.document_templates where company_id=company_row.id and lower(name)=lower(theme_name)) then
        structure_key:=case theme_name when 'Moderne' then 'modern-color' when 'Compact' then 'compact-header' else 'classic-balanced' end;
        config:=public._piloz_document_theme_default_configuration(structure_key);
        if theme_name='Moderne' then
          config:=jsonb_set(config,'{colors,primary}',to_jsonb('#13294B'::text),true);
          config:=jsonb_set(config,'{colors,secondary}',to_jsonb('#11BFAE'::text),true);
        elsif theme_name='Compact' then
          config:=jsonb_set(config,'{spacing}',jsonb_build_object('top',24,'bottom',30,'left',24,'right',24,'link_vertical',false,'link_horizontal',false),true);
          config:=jsonb_set(config,'{typography,title,size}',to_jsonb('small'::text),true);
          config:=jsonb_set(config,'{typography,content,size}',to_jsonb('small'::text),true);
          config:=jsonb_set(config,'{typography,table,size}',to_jsonb('small'::text),true);
        end if;
        insert into public.document_templates(
          company_id,name,document_type,language,status,is_default,current_version,is_system,supported_document_types,
          renderer_version,thumbnail_config,created_by,updated_by
        ) values(
          company_row.id,theme_name,'quote','fr','active',false,1,true,
          '["quote","invoice","sales_order","credit_note","deposit_invoice","balance_invoice","progress_invoice","purchase_order"]'::jsonb,
          'theme-renderer-v1',config,company_row.owner_user_id,company_row.owner_user_id
        ) returning id into created_theme_id;
        insert into public.document_template_versions(
          company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,logo_settings,
          visible_columns,header_fields,bank_details_visibility,document_title,client_profile,issuer_profile,payment_methods,
          configuration_json,renderer_version,configuration_checksum,created_by
        ) values(
          company_row.id,created_theme_id,1,'{}'::jsonb,'','','Thème système Piloz initial',
          case structure_key when 'modern-color' then 'modern' when 'compact-header' then 'compact' else 'classic' end,
          config->'colors',config->'logo',config->'table'->'columns','[]'::jsonb,'footer','Document',
          '{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,
          config,'theme-renderer-v1',encode(extensions.digest(convert_to(config::text,'UTF8'),'sha256'),'hex'),company_row.owner_user_id
        );
      end if;
    end loop;
  end loop;
end
$seed_themes$;

create or replace function public.seed_company_document_themes()
returns trigger language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare theme_name text; structure_key text; theme_id uuid; config jsonb; quote_theme uuid; invoice_theme uuid;
begin
  foreach theme_name in array array['Classique','Moderne','Compact'] loop
    structure_key:=case theme_name when 'Moderne' then 'modern-color' when 'Compact' then 'compact-header' else 'classic-balanced' end;
    config:=public._piloz_document_theme_default_configuration(structure_key);
    if theme_name='Moderne' then
      config:=jsonb_set(config,'{colors,primary}',to_jsonb('#13294B'::text),true);
      config:=jsonb_set(config,'{colors,secondary}',to_jsonb('#11BFAE'::text),true);
    elsif theme_name='Compact' then
      config:=jsonb_set(config,'{spacing}',jsonb_build_object('top',24,'bottom',30,'left',24,'right',24,'link_vertical',false,'link_horizontal',false),true);
      config:=jsonb_set(config,'{typography,title,size}',to_jsonb('small'::text),true);
      config:=jsonb_set(config,'{typography,content,size}',to_jsonb('small'::text),true);
      config:=jsonb_set(config,'{typography,table,size}',to_jsonb('small'::text),true);
    end if;
    insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,is_system,
      supported_document_types,renderer_version,thumbnail_config,created_by,updated_by)
    values(new.id,theme_name,'quote','fr','active',false,1,true,
      '["quote","invoice","sales_order","credit_note","deposit_invoice","balance_invoice","progress_invoice","purchase_order"]'::jsonb,
      'theme-renderer-v1',config,new.owner_user_id,new.owner_user_id)
    on conflict do nothing returning id into theme_id;
    if theme_id is not null then
      insert into public.document_template_versions(company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,
        color_settings,logo_settings,visible_columns,header_fields,bank_details_visibility,document_title,client_profile,issuer_profile,
        payment_methods,configuration_json,renderer_version,configuration_checksum,created_by)
      values(new.id,theme_id,1,'{}'::jsonb,'','','Thème système Piloz initial',
        case structure_key when 'modern-color' then 'modern' when 'compact-header' then 'compact' else 'classic' end,
        config->'colors',config->'logo',config->'table'->'columns','[]'::jsonb,'footer','Document',
        '{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,config,'theme-renderer-v1',
        encode(extensions.digest(convert_to(config::text,'UTF8'),'sha256'),'hex'),new.owner_user_id);
    end if;
  end loop;
  select default_quote_template_id,default_invoice_template_id into quote_theme,invoice_theme
  from public.company_document_settings where company_id=new.id;
  select coalesce(quote_theme,id) into quote_theme from public.document_templates where company_id=new.id and status='active'
    order by (id=quote_theme) desc,is_system desc,created_at asc limit 1;
  select coalesce(invoice_theme,id) into invoice_theme from public.document_templates where company_id=new.id and status='active'
    order by (id=invoice_theme) desc,is_system desc,created_at asc limit 1;
  if quote_theme is not null then
    foreach theme_name in array array['quote','sales_order'] loop
      insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
      values(new.id,theme_name,quote_theme,new.owner_user_id,new.owner_user_id) on conflict(company_id,document_type) do nothing;
    end loop;
  end if;
  if invoice_theme is not null then
    foreach theme_name in array array['invoice','deposit_invoice','balance_invoice','progress_invoice','credit_note','purchase_order'] loop
      insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
      values(new.id,theme_name,invoice_theme,new.owner_user_id,new.owner_user_id) on conflict(company_id,document_type) do nothing;
    end loop;
  end if;
  return new;
end
$$;
revoke all on function public.seed_company_document_themes() from public,anon,authenticated;
drop trigger if exists companies_seed_document_themes on public.companies;
create trigger companies_seed_document_themes after insert on public.companies
for each row execute function public.seed_company_document_themes();

-- Migrate the existing quote/invoice defaults to the new assignment table.
insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
select settings.company_id,'quote',settings.default_quote_template_id,company.owner_user_id,company.owner_user_id
from public.company_document_settings settings join public.companies company on company.id=settings.company_id
join public.document_templates theme on theme.id=settings.default_quote_template_id and theme.status='active'
where settings.default_quote_template_id is not null
on conflict(company_id,document_type) do nothing;

insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
select settings.company_id,'invoice',settings.default_invoice_template_id,company.owner_user_id,company.owner_user_id
from public.company_document_settings settings join public.companies company on company.id=settings.company_id
join public.document_templates theme on theme.id=settings.default_invoice_template_id and theme.status='active'
where settings.default_invoice_template_id is not null
on conflict(company_id,document_type) do nothing;

insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
select settings.company_id,target.document_type,settings.default_invoice_template_id,company.owner_user_id,company.owner_user_id
from public.company_document_settings settings join public.companies company on company.id=settings.company_id
join public.document_templates theme on theme.id=settings.default_invoice_template_id and theme.status='active'
cross join (values('credit_note'),('deposit_invoice'),('balance_invoice'),('progress_invoice')) target(document_type)
where settings.default_invoice_template_id is not null
on conflict(company_id,document_type) do nothing;

-- Guarantee one usable default for every supported document type, including
-- companies whose legacy quote/invoice defaults were empty.
insert into public.document_theme_assignments(company_id,document_type,theme_id,created_by,updated_by)
select company.id,target.document_type,candidate.id,company.owner_user_id,company.owner_user_id
from public.companies company
cross join (values('quote'),('invoice'),('sales_order'),('credit_note'),('deposit_invoice'),('balance_invoice'),('progress_invoice'),('purchase_order')) target(document_type)
cross join lateral (
  select theme.id from public.document_templates theme
  where theme.company_id=company.id and theme.status='active'
    and (theme.supported_document_types ? target.document_type or theme.document_type=target.document_type)
  order by theme.is_default desc,theme.is_system desc,theme.created_at asc limit 1
) candidate
on conflict(company_id,document_type) do nothing;

do $theme_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'document_theme_assignments','document_theme_assets','document_theme_links','document_theme_footer_logos',
    'document_theme_usage','document_theme_user_preferences'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.is_company_member(company_id))',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for insert to authenticated with check(public._piloz_can_manage_document_themes(company_id) and created_by=auth.uid())',table_name||'_insert',table_name);
    execute format('create policy %I on public.%I for update to authenticated using(public._piloz_can_manage_document_themes(company_id)) with check(public._piloz_can_manage_document_themes(company_id))',table_name||'_update',table_name);
    execute format('create policy %I on public.%I for delete to authenticated using(public._piloz_can_manage_document_themes(company_id))',table_name||'_delete',table_name);
  end loop;
end
$theme_rls$;

-- A user may maintain only their own editor preference row.
drop policy if exists document_theme_user_preferences_insert on public.document_theme_user_preferences;
drop policy if exists document_theme_user_preferences_update on public.document_theme_user_preferences;
drop policy if exists document_theme_user_preferences_delete on public.document_theme_user_preferences;
create policy document_theme_user_preferences_insert on public.document_theme_user_preferences for insert to authenticated
  with check(public.is_company_member(company_id) and user_id=auth.uid());
create policy document_theme_user_preferences_update on public.document_theme_user_preferences for update to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid())
  with check(public.is_company_member(company_id) and user_id=auth.uid());
create policy document_theme_user_preferences_delete on public.document_theme_user_preferences for delete to authenticated
  using(public.is_company_member(company_id) and user_id=auth.uid());

-- Extend the official private asset bucket with WEBP support. Existing Storage
-- isolation policies already scope paths by company id and limit writes to
-- owners/admins.
update storage.buckets set allowed_mime_types=array['image/png','image/jpeg','image/webp','image/svg+xml']
where id='company-assets';

drop policy if exists company_assets_insert on storage.objects;
create policy company_assets_insert on storage.objects for insert to authenticated with check(
  bucket_id='company-assets' and (
    public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
    or ((storage.foldername(name))[2]='themes' and public._piloz_can_manage_document_themes((storage.foldername(name))[1]::uuid))
  )
);
drop policy if exists company_assets_update on storage.objects;
create policy company_assets_update on storage.objects for update to authenticated using(
  bucket_id='company-assets' and (
    public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
    or ((storage.foldername(name))[2]='themes' and public._piloz_can_manage_document_themes((storage.foldername(name))[1]::uuid))
  )
) with check(
  bucket_id='company-assets' and (
    public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
    or ((storage.foldername(name))[2]='themes' and public._piloz_can_manage_document_themes((storage.foldername(name))[1]::uuid))
  )
);
drop policy if exists company_assets_delete on storage.objects;
create policy company_assets_delete on storage.objects for delete to authenticated using(
  bucket_id='company-assets' and (
    public.has_company_role((storage.foldername(name))[1]::uuid,array['owner','admin'])
    or ((storage.foldername(name))[2]='themes' and public._piloz_can_manage_document_themes((storage.foldername(name))[1]::uuid))
  )
);

grant select on public.document_theme_assignments,public.document_theme_assets,public.document_theme_links,
  public.document_theme_footer_logos,public.document_theme_usage,public.document_theme_user_preferences to authenticated;
grant insert,update,delete on public.document_theme_assignments,public.document_theme_assets,public.document_theme_links,
  public.document_theme_footer_logos,public.document_theme_user_preferences to authenticated;
grant select(configuration_json,renderer_version,configuration_checksum,parent_version_id) on public.document_template_versions to authenticated;
grant select(theme_id,theme_version,theme_snapshot) on public.documents to authenticated;

revoke all on function public._piloz_document_theme_default_configuration(text) from public,anon;
revoke all on function public.normalize_document_theme_configuration(jsonb) from public,anon;
revoke all on function public._piloz_can_manage_document_themes(uuid) from public,anon;
grant execute on function public._piloz_can_manage_document_themes(uuid) to authenticated;
revoke all on function public._piloz_document_theme_unique_name(uuid,text) from public,anon;
revoke all on function public.create_document_theme(uuid,uuid) from public,anon;
revoke all on function public.save_document_theme(uuid,text,jsonb,jsonb) from public,anon;
revoke all on function public.rename_document_theme(uuid,text) from public,anon;
revoke all on function public.assign_document_theme(uuid,text) from public,anon;
revoke all on function public.archive_document_theme(uuid) from public,anon;
revoke all on function public.delete_document_theme(uuid) from public,anon;
revoke all on function public._piloz_sync_document_theme() from public,anon,authenticated;
revoke all on function public._piloz_record_document_theme_usage() from public,anon,authenticated;

grant execute on function public._piloz_document_theme_default_configuration(text) to authenticated,service_role;
grant execute on function public.normalize_document_theme_configuration(jsonb) to authenticated,service_role;
grant execute on function public.create_document_theme(uuid,uuid) to authenticated;
grant execute on function public.save_document_theme(uuid,text,jsonb,jsonb) to authenticated;
grant execute on function public.rename_document_theme(uuid,text) to authenticated;
grant execute on function public.assign_document_theme(uuid,text) to authenticated;
grant execute on function public.archive_document_theme(uuid) to authenticated;
grant execute on function public.delete_document_theme(uuid) to authenticated;

commit;
