begin;

-- Crée un pied de page par défaut avec toutes les mentions légales
-- obligatoires activées (mentions légales, coordonnées bancaires,
-- conditions de paiement, pénalités de retard, numéro de page — déjà
-- vrai par défaut sur document_footers), et le sélectionne automatiquement
-- sur les modèles de devis et de facture par défaut de chaque entreprise.

create or replace function public._piloz_seed_company_footer(target_company_id uuid,target_owner_user_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare footer_id uuid;
begin
  select id into footer_id from public.document_footers
  where company_id=target_company_id and is_default order by created_at limit 1;
  if footer_id is not null then return footer_id; end if;
  insert into public.document_footers(
    company_id,name,body,show_legal_mentions,show_bank_details,show_payment_terms,show_late_penalties,show_page_number,
    is_default,is_active,created_by
  ) values(
    target_company_id,'Mentions légales par défaut',null,true,true,true,true,true,
    true,true,target_owner_user_id
  ) returning id into footer_id;
  return footer_id;
end
$$;
revoke all on function public._piloz_seed_company_footer(uuid,uuid) from public,anon,authenticated;

create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc_type text; template_id uuid; template_name text; footer_id uuid;
begin
  footer_id:=public._piloz_seed_company_footer(target_company_id,target_owner_user_id);
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
      layout_key,color_settings,logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,
      document_title,free_field,client_profile,issuer_profile,created_by
    ) values(
      target_company_id,template_id,1,'{}'::jsonb,'','','Modèle initial',
      'classic','{}'::jsonb,
      jsonb_build_object('show',true,'use_alternate',false,'max_width',140),
      public._piloz_default_columns(),'[]'::jsonb,footer_id,'footer',
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

-- Rattrapage pour les entreprises déjà existantes : crée le pied de page
-- par défaut s'il n'existe pas, et le sélectionne uniquement sur les
-- modèles par défaut dont le pied de page n'a jamais été choisi
-- manuellement (footer_id encore null), sans écraser un choix existant.
do $backfill$
declare c record; default_footer_id uuid;
begin
  for c in select id,owner_user_id from public.companies loop
    default_footer_id:=public._piloz_seed_company_footer(c.id,c.owner_user_id);
    update public.document_template_versions tv set footer_id=default_footer_id
    from public.document_templates t
    where tv.template_id=t.id and t.company_id=c.id and t.is_default
      and tv.version=t.current_version and tv.footer_id is null;
  end loop;
end
$backfill$;

commit;
