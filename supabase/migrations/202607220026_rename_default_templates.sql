begin;

-- Renomme les modèles "Modèle par défaut" en noms explicites par type, pour
-- que la liste des modèles soit immédiatement lisible (un modèle par type
-- de document, chacun par défaut pour son type).
update public.document_templates set name='Modèle devis défaut'
  where name='Modèle par défaut' and document_type='quote';
update public.document_templates set name='Modèle facture défaut'
  where name='Modèle par défaut' and document_type='invoice';

create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc_type text; template_id uuid; template_name text;
begin
  foreach doc_type in array array['quote','invoice'] loop
    if exists(select 1 from public.document_templates where company_id=target_company_id and document_type=doc_type) then
      continue;
    end if;
    template_name:=case doc_type when 'quote' then 'Modèle devis défaut' else 'Modèle facture défaut' end;
    insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
    values(target_company_id,template_name,doc_type,'fr','active',true,1,target_owner_user_id,target_owner_user_id)
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

commit;
