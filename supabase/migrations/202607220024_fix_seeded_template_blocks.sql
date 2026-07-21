begin;

-- La migration précédente (202607220023) créait les 6 modèles avec des
-- blocs vides (l'aperçu affichait une page blanche). Plus simple : chaque
-- modèle a désormais un contenu HTML complet et fixe, propre à sa mise en
-- page (Classique/Moderne/Compact) — l'utilisateur choisit un modèle tout
-- prêt, il ne compose plus de blocs un par un.
create or replace function public._piloz_template_preview_html(layout_key text,document_type text)
returns text language sql immutable as $$
  select
    '<header class="tpl-head tpl-'||layout_key||'"><div class="tpl-logo">{{company.logo}}</div><div class="tpl-issuer"><b>{{company.name}}</b><br>{{company.address}}<br>{{company.email}} · {{company.phone}}<br>SIRET {{company.siret}} · TVA {{company.vat_number}}</div></header>'||
    '<section class="tpl-meta"><h1>{{document.number}}</h1><p>'||(case when document_type='quote' then 'Émis le {{document.issue_date}} · Valable jusqu’au {{document.validity_date}}' else 'Émis le {{document.issue_date}} · Échéance {{document.due_date}}' end)||'</p><p class="tpl-subject">{{document.subject}}</p></section>'||
    '<section class="tpl-client"><h2>Destinataire</h2><b>{{client.name}}</b><br>{{client.address}}<br>{{client.email}}</section>'||
    '<section class="tpl-lines">{{document.lines}}</section>'||
    '<section class="tpl-totals"><p>Total HT : <b>{{document.total_ht}}</b></p><p>TVA : <b>{{document.total_vat}}</b></p><p class="tpl-grand-total">Total TTC : <b>{{document.total_ttc}}</b></p></section>'||
    '<footer class="tpl-foot"><p>{{document.payment_terms}} · IBAN {{document.iban}} · BIC {{document.bic}}</p></footer>'
$$;

create or replace function public._piloz_template_preview_css(layout_key text,colors jsonb)
returns text language sql immutable as $$
  select
    'body{font-family:Arial,Helvetica,sans-serif;color:'||coalesce(colors->>'text','#14202f')||';margin:0;padding:24px}'||
    '.tpl-head{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid '||coalesce(colors->>'primary','#0d6e73')||';padding-bottom:14px;margin-bottom:18px}'||
    '.tpl-head h1,.tpl-meta h1{color:'||coalesce(colors->>'heading','#14202f')||'}'||
    '.tpl-issuer{text-align:right;font-size:.85rem}'||
    'section{margin:14px 0;padding:'||(case when layout_key='compact' then '8px' else '14px' end)||';background:'||coalesce(colors->>'tableBackground','#f5f7f8')||';border:1px solid '||coalesce(colors->>'border','#d9e0e8')||';border-radius:8px}'||
    (case when layout_key='modern' then '.tpl-meta{background:'||coalesce(colors->>'primary','#0f766e')||';color:#fff;border:0}.tpl-meta h1{color:#fff}' else '' end)||
    '.tpl-grand-total{font-size:1.2rem;font-weight:800;color:'||coalesce(colors->>'primary','#0d6e73')||'}'||
    '.tpl-lines table{width:100%;border-collapse:collapse}.tpl-lines td,.tpl-lines th{padding:8px;border-bottom:1px solid '||coalesce(colors->>'border','#ddd')||'}'||
    '.tpl-foot{font-size:.72rem;color:#68728a;border-top:1px solid '||coalesce(colors->>'border','#d9e0e8')||';padding-top:10px}'
$$;

-- Recalcule le contenu des 6 modèles déjà créés par la migration précédente.
update public.document_template_versions tv set
  visual_schema='{}'::jsonb,
  html=public._piloz_template_preview_html(tv.layout_key,t.document_type),
  css=public._piloz_template_preview_css(tv.layout_key,tv.color_settings)
from public.document_templates t
where t.id=tv.template_id and tv.change_comment='Modèle initial' and t.name in('Classique','Moderne','Compact');

-- Corrige la fonction de seed pour toute future entreprise : plus de
-- composition par blocs, un contenu complet et fixe par mise en page.
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare layout record; doc_type record; template_id uuid;
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
      insert into public.document_template_versions(
        company_id,template_id,version,visual_schema,html,css,change_comment,
        layout_key,color_settings,logo_settings,visible_columns,header_fields,bank_details_visibility,created_by
      ) values(
        target_company_id,template_id,1,'{}'::jsonb,
        public._piloz_template_preview_html(layout.layout_key,doc_type.document_type),
        public._piloz_template_preview_css(layout.layout_key,layout.colors),
        'Modèle initial',layout.layout_key,layout.colors,
        jsonb_build_object('show',true,'use_alternate',false,'max_width',case when layout.layout_key='compact' then 110 else 140 end),
        jsonb_build_object('discount',layout.layout_key<>'classic'),
        '[]'::jsonb,'footer',target_owner_user_id
      );
    end loop;
  end loop;
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

commit;
