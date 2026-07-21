begin;

-- Étend les modèles de documents avec des réglages structurés (mise en page,
-- couleurs, logo, colonnes visibles, en-tête, pied de page, visibilité des
-- coordonnées bancaires) au lieu du seul blob visual_schema libre. Ces
-- réglages vivent sur les VERSIONS de modèle, comme html/css, puisqu'ils
-- font partie du contenu versionné et historisable.
alter table public.document_template_versions
  add column if not exists layout_key text not null default 'classic',
  add column if not exists color_settings jsonb not null default '{}'::jsonb,
  add column if not exists logo_settings jsonb not null default '{}'::jsonb,
  add column if not exists visible_columns jsonb not null default '{}'::jsonb,
  add column if not exists header_fields jsonb not null default '[]'::jsonb,
  add column if not exists footer_id uuid,
  add column if not exists bank_details_visibility text not null default 'footer';

alter table public.document_template_versions drop constraint if exists document_template_versions_layout_key_check;
alter table public.document_template_versions add constraint document_template_versions_layout_key_check
  check(layout_key in('classic','modern','compact')) not valid;

alter table public.document_template_versions drop constraint if exists document_template_versions_bank_visibility_check;
alter table public.document_template_versions add constraint document_template_versions_bank_visibility_check
  check(bank_details_visibility in('hidden','body','summary','footer')) not valid;

-- ---------------------------------------------------------------------------
-- Pieds de page réutilisables entre modèles
-- ---------------------------------------------------------------------------
create table if not exists public.document_footers(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  body text,
  show_legal_mentions boolean not null default true,
  show_bank_details boolean not null default true,
  show_payment_terms boolean not null default true,
  show_late_penalties boolean not null default true,
  show_page_number boolean not null default true,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,name)
);
create unique index if not exists document_footers_company_id_id_uidx on public.document_footers(company_id,id);
create unique index if not exists document_footers_default_idx on public.document_footers(company_id) where is_default and is_active;

alter table public.document_template_versions drop constraint if exists document_template_versions_footer_company_fk;
alter table public.document_template_versions add constraint document_template_versions_footer_company_fk
  foreign key(company_id,footer_id) references public.document_footers(company_id,id) not valid;

alter table public.document_footers enable row level security;
drop policy if exists document_footers_select on public.document_footers;
drop policy if exists document_footers_insert on public.document_footers;
drop policy if exists document_footers_update on public.document_footers;
drop policy if exists document_footers_delete on public.document_footers;
create policy document_footers_select on public.document_footers for select to authenticated
  using(public.is_company_member(company_id));
create policy document_footers_insert on public.document_footers for insert to authenticated
  with check(public.is_company_member(company_id) and created_by=auth.uid());
create policy document_footers_update on public.document_footers for update to authenticated
  using(public.has_company_role(company_id,array['owner','admin']))
  with check(public.has_company_role(company_id,array['owner','admin']));
create policy document_footers_delete on public.document_footers for delete to authenticated
  using(public.has_company_role(company_id,array['owner','admin']));

drop trigger if exists document_footers_set_updated_at on public.document_footers;
create trigger document_footers_set_updated_at before update on public.document_footers
  for each row execute function public.set_current_timestamp_updated_at();

create or replace function public.enforce_single_footer_default()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.is_default then
    update public.document_footers set is_default=false,updated_at=now()
    where company_id=new.company_id and id<>new.id and is_default;
  end if;
  return new;
end
$$;
revoke all on function public.enforce_single_footer_default() from public,anon,authenticated;
drop trigger if exists document_footers_single_default on public.document_footers;
create trigger document_footers_single_default before insert or update of is_default on public.document_footers
  for each row execute function public.enforce_single_footer_default();

revoke all on public.document_footers from anon,authenticated;
grant select,insert,update,delete on public.document_footers to authenticated;

-- ---------------------------------------------------------------------------
-- save_document_template_version : ajoute les nouveaux réglages de mise en
-- page. L'ancienne signature (12 paramètres) est retirée pour éviter deux
-- surcharges coexistantes ; l'edge function appelante est mise à jour en
-- parallèle pour fournir tous les paramètres.
-- ---------------------------------------------------------------------------
drop function if exists public.save_document_template_version(uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text);

create or replace function public.save_document_template_version(
 target_company_id uuid,target_user_id uuid,target_template_id uuid,target_name text,target_document_type text,target_language text,
 target_status text,target_is_default boolean,target_visual_schema jsonb,target_html text,target_css text,target_comment text,
 target_layout_key text default 'classic',target_color_settings jsonb default '{}'::jsonb,target_logo_settings jsonb default '{}'::jsonb,
 target_visible_columns jsonb default '{}'::jsonb,target_header_fields jsonb default '[]'::jsonb,target_footer_id uuid default null,
 target_bank_details_visibility text default 'footer'
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare template_id uuid; next_version integer;
begin
 if not exists(select 1 from public.company_members where company_id=target_company_id and user_id=target_user_id and role in('owner','admin'))
 then raise exception 'forbidden' using errcode='42501'; end if;
 if nullif(trim(target_name),'') is null then raise exception 'template_name_required'; end if;
 if target_layout_key not in('classic','modern','compact') then raise exception 'invalid_layout_key'; end if;
 if target_bank_details_visibility not in('hidden','body','summary','footer') then raise exception 'invalid_bank_details_visibility'; end if;
 if target_footer_id is not null and not exists(select 1 from public.document_footers where id=target_footer_id and company_id=target_company_id) then
   raise exception 'footer_not_found';
 end if;
 if target_is_default then
  update public.document_templates set is_default=false,updated_at=now(),updated_by=target_user_id
  where company_id=target_company_id and document_type=target_document_type and language=target_language and is_default;
 end if;
 if target_template_id is null then
  insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
  values(target_company_id,target_name,target_document_type,target_language,target_status,target_is_default,1,target_user_id,target_user_id)
  returning id,current_version into template_id,next_version;
 else
  select id,current_version+1 into template_id,next_version from public.document_templates
  where id=target_template_id and company_id=target_company_id for update;
  if template_id is null then raise exception 'template_not_found'; end if;
  update public.document_templates set name=target_name,document_type=target_document_type,language=target_language,status=target_status,
   is_default=target_is_default,current_version=next_version,updated_by=target_user_id,updated_at=now() where id=template_id;
 end if;
 insert into public.document_template_versions(
   company_id,template_id,version,visual_schema,html,css,change_comment,
   layout_key,color_settings,logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,created_by
 )
 values(
   target_company_id,template_id,next_version,coalesce(target_visual_schema,'{}'::jsonb),coalesce(target_html,''),coalesce(target_css,''),
   coalesce(target_comment,'Nouvelle version'),target_layout_key,coalesce(target_color_settings,'{}'::jsonb),
   coalesce(target_logo_settings,'{}'::jsonb),coalesce(target_visible_columns,'{}'::jsonb),coalesce(target_header_fields,'[]'::jsonb),
   target_footer_id,target_bank_details_visibility,target_user_id
 );
 return jsonb_build_object('templateId',template_id,'version',next_version);
end $$;

revoke all on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text
) from public;
grant execute on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text
) to service_role;

commit;
