begin;

-- Compléments non destructifs pour la création client depuis les documents.
alter table public.clients
  add column if not exists billing_address_line_1 text,
  add column if not exists billing_address_line_2 text,
  add column if not exists billing_postal_code text,
  add column if not exists billing_city text,
  add column if not exists billing_country_code text;

grant select(
  billing_address_line_1,billing_address_line_2,billing_postal_code,billing_city,billing_country_code
) on public.clients to authenticated;

-- Un pied de page peut être le défaut des devis, des factures, ou des deux.
alter table public.document_footers
  add column if not exists is_default_quote boolean not null default false,
  add column if not exists is_default_invoice boolean not null default false;

update public.document_footers
set is_default_quote=true,is_default_invoice=true
where is_default and not (is_default_quote or is_default_invoice);

create unique index if not exists document_footers_default_quote_idx
  on public.document_footers(company_id) where is_default_quote and is_active;
create unique index if not exists document_footers_default_invoice_idx
  on public.document_footers(company_id) where is_default_invoice and is_active;

create or replace function public.enforce_footer_defaults_by_document_type()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.is_default_quote then
    update public.document_footers set is_default_quote=false,updated_at=now()
    where company_id=new.company_id and id<>new.id and is_default_quote;
  end if;
  if new.is_default_invoice then
    update public.document_footers set is_default_invoice=false,updated_at=now()
    where company_id=new.company_id and id<>new.id and is_default_invoice;
  end if;
  return new;
end
$$;
revoke all on function public.enforce_footer_defaults_by_document_type() from public,anon,authenticated;
drop trigger if exists document_footers_defaults_by_type on public.document_footers;
create trigger document_footers_defaults_by_type
before insert or update of is_default_quote,is_default_invoice on public.document_footers
for each row execute function public.enforce_footer_defaults_by_document_type();

create or replace function public._piloz_seed_company_footer(target_company_id uuid,target_owner_user_id uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare footer_id uuid;
begin
  select id into footer_id from public.document_footers
  where company_id=target_company_id and lower(name)=lower('Pied de page légal par défaut')
  order by created_at limit 1;
  if footer_id is null then
    select id into footer_id from public.document_footers
    where company_id=target_company_id and is_default order by created_at limit 1;
  end if;
  if footer_id is null then
    insert into public.document_footers(
      company_id,name,body,show_legal_mentions,show_bank_details,show_payment_terms,
      show_late_penalties,show_page_number,is_default,is_default_quote,is_default_invoice,is_active,created_by
    ) values(
      target_company_id,'Pied de page légal par défaut',null,true,true,true,true,true,true,true,true,true,target_owner_user_id
    ) returning id into footer_id;
  else
    update public.document_footers set
      name=case when not exists(
        select 1 from public.document_footers other where other.company_id=target_company_id
          and other.id<>footer_id and lower(other.name)=lower('Pied de page légal par défaut')
      ) then 'Pied de page légal par défaut' else name end,
      show_legal_mentions=true,show_bank_details=true,show_payment_terms=true,
      show_late_penalties=true,show_page_number=true,is_default=true,
      is_default_quote=true,is_default_invoice=true,is_active=true,updated_at=now()
    where id=footer_id;
  end if;
  return footer_id;
end
$$;
revoke all on function public._piloz_seed_company_footer(uuid,uuid) from public,anon,authenticated;

-- Garantit trois modèles réellement distincts et actifs pour chaque type,
-- sans modifier ni supprimer les modèles personnalisés de l'utilisateur.
create or replace function public._piloz_seed_document_templates(target_company_id uuid,target_owner_user_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare
  target_doc_type text; variant record; seeded_template_id uuid; default_footer_id uuid;
  quote_default uuid; invoice_default uuid;
begin
  default_footer_id:=public._piloz_seed_company_footer(target_company_id,target_owner_user_id);
  foreach target_doc_type in array array['quote','invoice'] loop
    for variant in select * from(values
      ('classic','Classique',jsonb_build_object('primary','#0d6e73','secondary','#0d6e73','heading','#14202f','border','#d9e0e8','tableBackground','#f5f7f8','text','#14202f','totals','#0d6e73')),
      ('modern','Moderne',jsonb_build_object('primary','#0f766e','secondary','#0891b2','heading','#0f172a','border','#cbd5e1','tableBackground','#ecfeff','text','#0f172a','totals','#0f766e')),
      ('compact','Compact',jsonb_build_object('primary','#334155','secondary','#475569','heading','#0f172a','border','#e2e8f0','tableBackground','#f8fafc','text','#1e293b','totals','#334155'))
    ) value(layout_key,label,colors) loop
      select id into seeded_template_id from public.document_templates
      where company_id=target_company_id and document_type=target_doc_type and language='fr'
        and lower(name)=lower(variant.label) and status='active'
      order by created_at limit 1;
      if seeded_template_id is null then
        insert into public.document_templates(
          company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by
        ) values(target_company_id,variant.label,target_doc_type,'fr','active',false,1,target_owner_user_id,target_owner_user_id)
        returning id into seeded_template_id;
        insert into public.document_template_versions(
          company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,
          logo_settings,visible_columns,header_fields,footer_id,bank_details_visibility,document_title,
          free_field,client_profile,issuer_profile,payment_methods,created_by
        ) values(
          target_company_id,seeded_template_id,1,'{}'::jsonb,'','','Modèle initial Piloz',variant.layout_key,variant.colors,
          jsonb_build_object('show',true,'use_alternate',false,'max_width',case when variant.layout_key='compact' then 110 else 140 end),
          public._piloz_default_columns(),'[]'::jsonb,default_footer_id,'footer',
          case when target_doc_type='quote' then 'Devis' else 'Facture' end,null,
          '{"show_email":true,"show_phone":true}'::jsonb,'{}'::jsonb,'["bank_transfer"]'::jsonb,target_owner_user_id
        );
      else
        update public.document_template_versions version set
          color_settings=coalesce(version.color_settings,'{}'::jsonb)||jsonb_build_object(
            'totals',coalesce(version.color_settings->>'totals',version.color_settings->>'primary',variant.colors->>'totals')
          ),
          footer_id=coalesce(version.footer_id,default_footer_id)
        from public.document_templates template
        where version.template_id=template.id and template.id=seeded_template_id and version.version=template.current_version;
      end if;
    end loop;

    if not exists(
      select 1 from public.document_templates where company_id=target_company_id
        and document_type=target_doc_type and language='fr' and status='active' and is_default
    ) then
      update public.document_templates set is_default=true,updated_at=now(),updated_by=target_owner_user_id
      where id=(select id from public.document_templates where company_id=target_company_id
        and document_type=target_doc_type and language='fr' and status='active'
        order by (lower(name)=lower('Classique')) desc,created_at limit 1);
    end if;
  end loop;

  select id into quote_default from public.document_templates
  where company_id=target_company_id and document_type='quote' and language='fr' and status='active' and is_default limit 1;
  select id into invoice_default from public.document_templates
  where company_id=target_company_id and document_type='invoice' and language='fr' and status='active' and is_default limit 1;
  insert into public.company_document_settings(company_id,default_quote_template_id,default_invoice_template_id)
  values(target_company_id,quote_default,invoice_default)
  on conflict(company_id) do update set
    default_quote_template_id=case when exists(
      select 1 from public.document_templates t where t.id=public.company_document_settings.default_quote_template_id
        and t.company_id=target_company_id and t.document_type='quote' and t.status='active'
    ) then public.company_document_settings.default_quote_template_id else excluded.default_quote_template_id end,
    default_invoice_template_id=case when exists(
      select 1 from public.document_templates t where t.id=public.company_document_settings.default_invoice_template_id
        and t.company_id=target_company_id and t.document_type='invoice' and t.status='active'
    ) then public.company_document_settings.default_invoice_template_id else excluded.default_invoice_template_id end;
end
$$;
revoke all on function public._piloz_seed_document_templates(uuid,uuid) from public,anon,authenticated;

do $backfill$
declare company_row record; company_footer_id uuid;
begin
  for company_row in select id,owner_user_id from public.companies loop
    perform public._piloz_seed_document_templates(company_row.id,company_row.owner_user_id);
    company_footer_id:=public._piloz_seed_company_footer(company_row.id,company_row.owner_user_id);
    update public.document_template_versions version set footer_id=company_footer_id
    from public.document_templates template
    where version.template_id=template.id and template.company_id=company_row.id
      and version.version=template.current_version and version.footer_id is null;
  end loop;
end
$backfill$;

commit;
