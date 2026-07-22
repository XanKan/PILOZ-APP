begin;

-- Conserve un modèle de devis et un modèle de facture à la création d'une
-- entreprise, sans archiver les modèles supplémentaires créés ensuite par les
-- utilisateurs (par exemple un modèle propre à chaque commercial).
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  target_doc_type text;
  selected_template_id uuid;
  default_footer_id uuid;
  quote_default uuid;
  invoice_default uuid;
  desired_name text;
begin
  default_footer_id:=public._piloz_seed_company_footer(target_company_id,target_owner_user_id);

  foreach target_doc_type in array array['quote','invoice'] loop
    desired_name:=case when target_doc_type='quote' then 'Modèle de devis' else 'Modèle de facture' end;
    selected_template_id:=null;

    -- Le choix enregistré dans les paramètres reste prioritaire s'il est
    -- toujours actif et appartient bien à l'entreprise.
    if target_doc_type='quote' then
      select template.id into selected_template_id
      from public.company_document_settings settings
      join public.document_templates template on template.id=settings.default_quote_template_id
      where settings.company_id=target_company_id and template.company_id=target_company_id
        and template.document_type='quote' and template.status='active';
    else
      select template.id into selected_template_id
      from public.company_document_settings settings
      join public.document_templates template on template.id=settings.default_invoice_template_id
      where settings.company_id=target_company_id and template.company_id=target_company_id
        and template.document_type='invoice' and template.status='active';
    end if;

    if selected_template_id is null then
      select id into selected_template_id from public.document_templates
      where company_id=target_company_id and document_type=target_doc_type
        and language='fr' and status='active'
      order by is_default desc,(lower(name)=lower(desired_name)) desc,created_at,id
      limit 1;
    end if;

    -- Une entreprise neuve reçoit exactement ces deux modèles. Aucun modèle
    -- supplémentaire n'est créé par le bootstrap.
    if selected_template_id is null then
      insert into public.document_templates(
        company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by
      ) values(
        target_company_id,desired_name,target_doc_type,'fr','active',true,1,target_owner_user_id,target_owner_user_id
      ) returning id into selected_template_id;

      insert into public.document_template_versions(
        company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,
        logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,document_title,
        free_field,client_profile,issuer_profile,payment_methods,created_by
      ) values(
        target_company_id,selected_template_id,1,'{}'::jsonb,'','','Modèle Piloz initial',
        'classic',
        '{"primary":"#111827","secondary":"#6b7280","heading":"#111827","border":"#d1d5db","tableBackground":"#f1f2f3","text":"#111827","totals":"#111827"}'::jsonb,
        '{"show":false,"use_alternate":false,"max_width":140}'::jsonb,
        public._piloz_default_columns(),'[]'::jsonb,default_footer_id,'footer',
        case when target_doc_type='quote' then 'Devis' else 'Facture' end,null,
        '{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,target_owner_user_id
      );
    elsif not exists(select 1 from public.document_templates where id=selected_template_id and is_default) then
      update public.document_templates set is_default=false,updated_at=now(),updated_by=target_owner_user_id
      where company_id=target_company_id and document_type=target_doc_type
        and language='fr' and is_default;
      update public.document_templates set is_default=true,updated_at=now(),updated_by=target_owner_user_id
      where id=selected_template_id;
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

-- Le backfill est idempotent : il répare uniquement les entreprises auxquelles
-- il manque un modèle actif et ne touche pas aux modèles archivés ou ajoutés.
do $backfill$
declare company_row record;
begin
  for company_row in select id,owner_user_id from public.companies loop
    perform public._piloz_seed_document_templates(company_row.id,company_row.owner_user_id);
  end loop;
end
$backfill$;

commit;
