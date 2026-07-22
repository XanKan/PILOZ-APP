begin;

-- Simplifie radicalement le système de modèles : plus de 3 variantes
-- (Classique/Moderne/Compact) auto-générées par type, plus de blocs, plus
-- de mode code/aperçu séparé. Chaque entreprise part avec UN modèle "par
-- défaut" par type (devis, facture), modifiable via un panneau de réglages
-- structuré (profil émetteur, profil client, contenu, colonnes, pied de
-- page, conditions de paiement) — l'utilisateur peut ensuite en créer
-- d'autres à la main.

-- Les modèles et références existants sont conservés. Seule l'implémentation
-- du seed est remplacée plus bas ; aucune donnée utilisateur n'est détachée
-- ou supprimée par cette migration.
drop trigger if exists companies_seed_document_templates on public.companies;
drop function if exists public.seed_company_document_templates();
drop function if exists public._piloz_seed_document_templates(uuid,uuid);
drop function if exists public._piloz_template_preview_html(text,text);
drop function if exists public._piloz_template_preview_css(text,jsonb);

-- Nouveaux réglages structurés : profil émetteur/client, intitulé,
-- champ libre. Les colonnes visibles réutilisent visible_columns (jsonb)
-- déjà existante, désormais au format tableau ordonné
-- [{key,label,visible,locked,position}], et header_fields (déjà existante)
-- au format [{label,value}].
alter table public.document_template_versions
  add column if not exists document_title text,
  add column if not exists free_field text,
  add column if not exists client_profile jsonb not null default '{"show_email":true,"show_phone":true}'::jsonb,
  add column if not exists issuer_profile jsonb not null default '{}'::jsonb;

create or replace function public._piloz_default_columns()
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('key','products','label','Produits','visible',true,'locked',true,'position',1),
    jsonb_build_object('key','quantity','label','Qté','visible',true,'locked',false,'position',2),
    jsonb_build_object('key','unit_price','label','Prix u. HT','visible',true,'locked',false,'position',3),
    jsonb_build_object('key','discount','label','Rem.','visible',false,'locked',false,'position',4),
    jsonb_build_object('key','tax_rate','label','TVA (%)','visible',true,'locked',false,'position',5),
    jsonb_build_object('key','total_excl_tax','label','Total HT','visible',true,'locked',false,'position',6),
    jsonb_build_object('key','total_incl_tax','label','Total TTC','visible',true,'locked',false,'position',7)
  )
$$;

-- Nouveau seed simplifié : un seul modèle "Modèle par défaut" par type.
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc_type text; template_id uuid;
begin
  foreach doc_type in array array['quote','invoice'] loop
    if exists(select 1 from public.document_templates where company_id=target_company_id and document_type=doc_type) then
      continue;
    end if;
    insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
    values(target_company_id,'Modèle par défaut',doc_type,'fr','active',true,1,target_owner_user_id,target_owner_user_id)
    returning id into template_id;
    insert into public.document_template_versions(
      company_id,template_id,version,visual_schema,html,css,change_comment,
      layout_key,color_settings,logo_settings,visible_columns,header_fields,bank_details_visibility,
      document_title,free_field,client_profile,issuer_profile,created_by
    ) values(
      target_company_id,template_id,1,'{}'::jsonb,'','','Modèle initial',
      'classic','{}'::jsonb,
      jsonb_build_object('show',true,'use_alternate',false,'max_width',140),
      public._piloz_default_columns(),'[]'::jsonb,'footer',
      case doc_type when 'quote' then 'Devis' else 'Facture' end,
      null,'{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,target_owner_user_id
    );
  end loop;
  insert into public.company_document_settings(company_id,default_quote_template_id,default_invoice_template_id)
  values(
    target_company_id,
    (select id from public.document_templates where company_id=target_company_id and document_type='quote' order by created_at limit 1),
    (select id from public.document_templates where company_id=target_company_id and document_type='invoice' order by created_at limit 1)
  )
  on conflict(company_id) do update set
    default_quote_template_id=coalesce(public.company_document_settings.default_quote_template_id,excluded.default_quote_template_id),
    default_invoice_template_id=coalesce(public.company_document_settings.default_invoice_template_id,excluded.default_invoice_template_id);
end
$$;
revoke all on function public._piloz_seed_document_templates(uuid,uuid) from public,anon,authenticated;

create or replace function public.seed_company_document_templates()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform public._piloz_seed_document_templates(new.id,new.owner_user_id);
  return new;
end
$$;
drop trigger if exists companies_seed_document_templates on public.companies;
create trigger companies_seed_document_templates after insert on public.companies
  for each row execute function public.seed_company_document_templates();

-- Rattrapage idempotent pour les entreprises existantes.
do $backfill$
declare c record;
begin
  for c in select id,owner_user_id from public.companies loop
    perform public._piloz_seed_document_templates(c.id,c.owner_user_id);
  end loop;
end
$backfill$;

-- ---------------------------------------------------------------------------
-- save_document_template_version : ajoute les 4 nouveaux réglages (intitulé,
-- champ libre, profil client, profil émetteur). Signature étendue en fin de
-- liste (paramètres par défaut) pour rester compatible autant que possible.
-- ---------------------------------------------------------------------------
drop function if exists public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text
);

create or replace function public.save_document_template_version(
 target_company_id uuid,target_user_id uuid,target_template_id uuid,target_name text,target_document_type text,target_language text,
 target_status text,target_is_default boolean,target_visual_schema jsonb,target_html text,target_css text,target_comment text,
 target_layout_key text default 'classic',target_color_settings jsonb default '{}'::jsonb,target_logo_settings jsonb default '{}'::jsonb,
 target_visible_columns jsonb default '[]'::jsonb,target_header_fields jsonb default '[]'::jsonb,target_footer_id uuid default null,
 target_bank_details_visibility text default 'footer',target_document_title text default null,target_free_field text default null,
 target_client_profile jsonb default '{"show_email":true,"show_phone":true}'::jsonb,target_issuer_profile jsonb default '{}'::jsonb
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
   layout_key,color_settings,logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,
   document_title,free_field,client_profile,issuer_profile,created_by
 )
 values(
   target_company_id,template_id,next_version,coalesce(target_visual_schema,'{}'::jsonb),coalesce(target_html,''),coalesce(target_css,''),
   coalesce(target_comment,'Nouvelle version'),target_layout_key,coalesce(target_color_settings,'{}'::jsonb),
   coalesce(target_logo_settings,'{}'::jsonb),coalesce(target_visible_columns,public._piloz_default_columns()),coalesce(target_header_fields,'[]'::jsonb),
   target_footer_id,target_bank_details_visibility,
   coalesce(nullif(trim(target_document_title),''),case when target_document_type='quote' then 'Devis' else 'Facture' end),
   nullif(target_free_field,''),coalesce(target_client_profile,'{"show_email":true,"show_phone":true}'::jsonb),
   coalesce(target_issuer_profile,'{}'::jsonb),target_user_id
 );
 return jsonb_build_object('templateId',template_id,'version',next_version);
end $$;

revoke all on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb
) from public;
grant execute on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb
) to service_role;

commit;
