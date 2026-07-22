begin;

-- Ajoute la liste des moyens de paiement acceptés par défaut pour un modèle
-- (case à cocher style iOS côté éditeur). Valeurs possibles : bank_transfer,
-- card, check, cash, direct_debit.
alter table public.document_template_versions
  add column if not exists payment_methods jsonb not null default '["bank_transfer"]'::jsonb;

drop function if exists public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb
);

create or replace function public.save_document_template_version(
 target_company_id uuid,target_user_id uuid,target_template_id uuid,target_name text,target_document_type text,target_language text,
 target_status text,target_is_default boolean,target_visual_schema jsonb,target_html text,target_css text,target_comment text,
 target_layout_key text default 'classic',target_color_settings jsonb default '{}'::jsonb,target_logo_settings jsonb default '{}'::jsonb,
 target_visible_columns jsonb default '[]'::jsonb,target_header_fields jsonb default '[]'::jsonb,target_footer_id uuid default null,
 target_bank_details_visibility text default 'footer',target_document_title text default null,target_free_field text default null,
 target_client_profile jsonb default '{"show_email":true,"show_phone":true}'::jsonb,target_issuer_profile jsonb default '{}'::jsonb,
 target_payment_methods jsonb default '["bank_transfer"]'::jsonb
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
   document_title,free_field,client_profile,issuer_profile,payment_methods,created_by
 )
 values(
   target_company_id,template_id,next_version,coalesce(target_visual_schema,'{}'::jsonb),coalesce(target_html,''),coalesce(target_css,''),
   coalesce(target_comment,'Nouvelle version'),target_layout_key,coalesce(target_color_settings,'{}'::jsonb),
   coalesce(target_logo_settings,'{}'::jsonb),coalesce(target_visible_columns,public._piloz_default_columns()),coalesce(target_header_fields,'[]'::jsonb),
   target_footer_id,target_bank_details_visibility,
   coalesce(nullif(trim(target_document_title),''),case when target_document_type='quote' then 'Devis' else 'Facture' end),
   nullif(target_free_field,''),coalesce(target_client_profile,'{"show_email":true,"show_phone":true}'::jsonb),
   coalesce(target_issuer_profile,'{}'::jsonb),coalesce(target_payment_methods,'["bank_transfer"]'::jsonb),target_user_id
 );
 return jsonb_build_object('templateId',template_id,'version',next_version);
end $$;

revoke all on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb,jsonb
) from public;
grant execute on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb,jsonb
) to service_role;

commit;
