begin;

-- Crée automatiquement 6 modèles de documents par entreprise : 3 mises en
-- page (Classique/Moderne/Compact) pour les devis, et les 3 mêmes pour les
-- factures. "Classique" est le modèle par défaut de chaque type. Ces
-- modèles utilisent directement les nouvelles colonnes structurées
-- (layout_key, color_settings...) : le PDF final en tient compte
-- immédiatement, sans configuration manuelle préalable.
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  layout record; doc_type record; template_id uuid; blocks jsonb;
  default_html text:='<div data-block-id="entreprise" data-block="entreprise"></div><div data-block-id="document" data-block="document"></div><div data-block-id="client" data-block="client"></div><div data-block-id="articles" data-block="articles"></div><div data-block-id="totaux" data-block="totaux"></div><div data-block-id="paiement" data-block="paiement"></div>';
  default_css text:='body{font-family:Arial,sans-serif;color:#172038} section{margin:16px 0} .document-lines{width:100%;border-collapse:collapse} .document-lines td,.document-lines th{padding:8px;border-bottom:1px solid #ddd}';
begin
  for doc_type in select * from(values('quote'),('invoice'))v(document_type) loop
    for layout in select * from(values
      ('classic','Classique',true,jsonb_build_object('primary','#0d6e73','secondary','#0d6e73','heading','#14202f','border','#d9e0e8','tableBackground','#f5f7f8','text','#14202f')),
      ('modern','Moderne',false,jsonb_build_object('primary','#0f766e','secondary','#0891b2','heading','#0f172a','border','#cbd5e1','tableBackground','#ecfeff','text','#0f172a')),
      ('compact','Compact',false,jsonb_build_object('primary','#334155','secondary','#475569','heading','#0f172a','border','#e2e8f0','tableBackground','#f8fafc','text','#1e293b'))
    )v(layout_key,label,is_default_layout,colors) loop
      if exists(select 1 from public.document_templates where company_id=target_company_id and document_type=doc_type.document_type and name=layout.label) then
        continue;
      end if;
      insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
      values(target_company_id,layout.label,doc_type.document_type,'fr','active',layout.is_default_layout,1,target_owner_user_id,target_owner_user_id)
      returning id into template_id;
      blocks:=jsonb_build_array(
        jsonb_build_object('id',gen_random_uuid(),'type','entreprise','label','Entreprise'),
        jsonb_build_object('id',gen_random_uuid(),'type','document','label','Document'),
        jsonb_build_object('id',gen_random_uuid(),'type','client','label','Client'),
        jsonb_build_object('id',gen_random_uuid(),'type','articles','label','Articles'),
        jsonb_build_object('id',gen_random_uuid(),'type','totaux','label','Totaux'),
        jsonb_build_object('id',gen_random_uuid(),'type','paiement','label','Paiement')
      );
      insert into public.document_template_versions(
        company_id,template_id,version,visual_schema,html,css,change_comment,
        layout_key,color_settings,logo_settings,visible_columns,header_fields,bank_details_visibility,created_by
      ) values(
        target_company_id,template_id,1,jsonb_build_object('blocks',blocks),default_html,default_css,'Modèle initial',
        layout.layout_key,layout.colors,
        jsonb_build_object('show',true,'use_alternate',false,'max_width',case when layout.layout_key='compact' then 110 else 140 end),
        jsonb_build_object('discount',layout.layout_key<>'classic'),
        '[]'::jsonb,'footer',target_owner_user_id
      );
    end loop;
  end loop;
  -- Relie les modèles "Classique" nouvellement créés comme modèle par défaut
  -- de l'entreprise, uniquement si aucun choix n'existe déjà (on ne doit
  -- jamais écraser une préférence déjà enregistrée). company_document_settings
  -- n'est pas toujours créée à cet instant (elle apparaît souvent plus tard,
  -- à l'onboarding) : on l'amorce ici si besoin, un upsert applicatif
  -- ultérieur (merge-duplicates) ne touchera que ses propres colonnes.
  insert into public.company_document_settings(company_id,default_quote_template_id,default_invoice_template_id)
  values(
    target_company_id,
    (select id from public.document_templates where company_id=target_company_id and document_type='quote' and name='Classique' limit 1),
    (select id from public.document_templates where company_id=target_company_id and document_type='invoice' and name='Classique' limit 1)
  )
  on conflict(company_id) do update set
    default_quote_template_id=coalesce(public.company_document_settings.default_quote_template_id,excluded.default_quote_template_id),
    default_invoice_template_id=coalesce(public.company_document_settings.default_invoice_template_id,excluded.default_invoice_template_id);
end
$$;
revoke all on function public._piloz_seed_document_templates(uuid,uuid) from public,anon,authenticated;

-- Nouvelle entreprise : seed automatique à la création.
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

-- Entreprises déjà existantes : rattrapage ponctuel, idempotent (ne
-- duplique jamais un modèle de même nom déjà présent).
do $backfill$
declare c record;
begin
  for c in select id,owner_user_id from public.companies loop
    perform public._piloz_seed_document_templates(c.id,c.owner_user_id);
  end loop;
end
$backfill$;

commit;
