begin;

-- Un seul modèle actif par entreprise et par famille de document. Les anciens
-- modèles sont archivés (jamais supprimés) afin de préserver les documents et
-- versions historiques qui les référencent.
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  target_doc_type text;
  selected_template_id uuid;
  selected_version integer;
  default_footer_id uuid;
  quote_default uuid;
  invoice_default uuid;
  desired_name text;
begin
  default_footer_id:=public._piloz_seed_company_footer(target_company_id,target_owner_user_id);

  foreach target_doc_type in array array['quote','invoice'] loop
    desired_name:=case when target_doc_type='quote' then 'Modèle de devis' else 'Modèle de facture' end;
    selected_template_id:=null;

    -- Conserve en priorité le modèle déjà choisi par l'entreprise.
    if target_doc_type='quote' then
      select settings.default_quote_template_id into selected_template_id
      from public.company_document_settings settings
      join public.document_templates template on template.id=settings.default_quote_template_id
      where settings.company_id=target_company_id and template.company_id=target_company_id
        and template.document_type='quote';
    else
      select settings.default_invoice_template_id into selected_template_id
      from public.company_document_settings settings
      join public.document_templates template on template.id=settings.default_invoice_template_id
      where settings.company_id=target_company_id and template.company_id=target_company_id
        and template.document_type='invoice';
    end if;

    if selected_template_id is null then
      select id into selected_template_id from public.document_templates
      where company_id=target_company_id and document_type=target_doc_type
      order by (lower(name)=lower(desired_name)) desc,is_default desc,(status='active') desc,created_at,id
      limit 1;
    end if;

    if selected_template_id is null then
      insert into public.document_templates(
        company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by
      ) values(
        target_company_id,desired_name,target_doc_type,'fr','archived',false,1,target_owner_user_id,target_owner_user_id
      ) returning id,current_version into selected_template_id,selected_version;
    else
      select current_version into selected_version from public.document_templates where id=selected_template_id;
    end if;

    -- Désactive d'abord tous les modèles pour respecter l'index unique du
    -- modèle par défaut, puis réactive uniquement celui qui a été retenu.
    update public.document_templates set
      status='archived',is_default=false,updated_at=now(),updated_by=target_owner_user_id
    where company_id=target_company_id and document_type=target_doc_type;

    update public.document_templates set
      name=desired_name,language='fr',status='active',is_default=true,updated_at=now(),updated_by=target_owner_user_id
    where id=selected_template_id;

    if not exists(
      select 1 from public.document_template_versions
      where template_id=selected_template_id and version=selected_version
    ) then
      insert into public.document_template_versions(
        company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,
        logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,document_title,
        free_field,client_profile,issuer_profile,payment_methods,created_by
      ) values(
        target_company_id,selected_template_id,selected_version,'{}'::jsonb,'','','Modèle unique Piloz',
        'classic',
        '{"primary":"#111827","secondary":"#6b7280","heading":"#111827","border":"#d1d5db","tableBackground":"#f1f2f3","text":"#111827","totals":"#111827"}'::jsonb,
        '{"show":false,"use_alternate":false,"max_width":140}'::jsonb,
        public._piloz_default_columns(),'[]'::jsonb,default_footer_id,'footer',
        case when target_doc_type='quote' then 'Devis' else 'Facture' end,null,
        '{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,target_owner_user_id
      );
    else
      update public.document_template_versions set
        layout_key='classic',
        color_settings='{"primary":"#111827","secondary":"#6b7280","heading":"#111827","border":"#d1d5db","tableBackground":"#f1f2f3","text":"#111827","totals":"#111827"}'::jsonb,
        logo_settings=coalesce(logo_settings,'{}'::jsonb)||'{"show":false,"use_alternate":false,"max_width":140}'::jsonb,
        visible_columns=public._piloz_default_columns(),
        footer_id=coalesce(footer_id,default_footer_id),
        bank_details_visibility='footer',
        document_title=case when target_doc_type='quote' then 'Devis' else 'Facture' end,
        change_comment='Modèle unique aligné sur le PDF de référence'
      where template_id=selected_template_id and version=selected_version;
    end if;

    if target_doc_type='quote' then quote_default:=selected_template_id;
    else invoice_default:=selected_template_id;
    end if;
  end loop;

  insert into public.company_document_settings(company_id,default_quote_template_id,default_invoice_template_id)
  values(target_company_id,quote_default,invoice_default)
  on conflict(company_id) do update set
    default_quote_template_id=excluded.default_quote_template_id,
    default_invoice_template_id=excluded.default_invoice_template_id,
    updated_at=now();
end
$$;

revoke all on function public._piloz_seed_document_templates(uuid,uuid) from public,anon,authenticated;

do $backfill$
declare company_row record;
begin
  for company_row in select id,owner_user_id from public.companies loop
    perform public._piloz_seed_document_templates(company_row.id,company_row.owner_user_id);
  end loop;
end
$backfill$;

commit;
