-- Déduction d'acompte sur les factures/situations et CGV versionnées.
-- Migration additive : aucune facture finalisée existante n'est modifiée.

begin;

alter table public.document_template_versions
  add column if not exists terms_conditions text;

alter table public.document_template_versions
  drop constraint if exists document_template_versions_terms_conditions_length;
alter table public.document_template_versions
  add constraint document_template_versions_terms_conditions_length
  check(terms_conditions is null or char_length(terms_conditions)<=30000);

comment on column public.document_template_versions.terms_conditions is
  'Conditions générales de vente figées avec la version du modèle, 30000 caractères maximum.';

create or replace function public._piloz_document_deposit_deduction(
  target_document_id uuid,
  target_metadata jsonb,
  gross_excl_tax numeric,
  gross_tax numeric,
  gross_incl_tax numeric
) returns jsonb
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare
  target public.documents%rowtype;
  root_id uuid;
  deposit_excl numeric:=0;
  deposit_tax numeric:=0;
  deposit_incl numeric:=0;
  previous_deduction numeric:=0;
  available numeric:=0;
  requested numeric:=0;
  deduction_incl numeric:=0;
  deduction_excl numeric:=0;
  deduction_tax numeric:=0;
  progress_ratio numeric:=0;
  mode text;
begin
  select * into target from public.documents where id=target_document_id;
  if target.id is null or target.document_type not in('invoice','balance_invoice') then
    return jsonb_build_object('mode','none','deduction_excl_tax',0,'deduction_tax',0,'deduction_incl_tax',0);
  end if;
  root_id:=public._piloz_document_root_quote(target.id);
  if root_id is null then
    return jsonb_build_object('mode','none','deduction_excl_tax',0,'deduction_tax',0,'deduction_incl_tax',0);
  end if;

  with related as(
    select distinct document.*
    from public.documents document
    left join public.document_links link on link.target_document_id=document.id
      and link.company_id=document.company_id and link.source_document_id=root_id
    where document.company_id=target.company_id and document.id<>target.id
      and document.status not in('cancelled','archived')
      and (link.link_type in('invoice','deposit','progress','balance') or document.source_document_id=root_id)
  )
  select
    coalesce(sum(total_excl_tax) filter(where document_type='deposit_invoice' and
      (finalized_at is not null or validated_at is not null or locked_at is not null or status in('finalized','validated','sent','overdue','partially_paid','paid'))),0),
    coalesce(sum(total_tax) filter(where document_type='deposit_invoice' and
      (finalized_at is not null or validated_at is not null or locked_at is not null or status in('finalized','validated','sent','overdue','partially_paid','paid'))),0),
    coalesce(sum(total_incl_tax) filter(where document_type='deposit_invoice' and
      (finalized_at is not null or validated_at is not null or locked_at is not null or status in('finalized','validated','sent','overdue','partially_paid','paid'))),0),
    coalesce(sum(coalesce(nullif(metadata->>'deposit_deduction_ttc','')::numeric,0)) filter(where document_type<>'deposit_invoice' and
      (finalized_at is not null or validated_at is not null or locked_at is not null or status in('finalized','validated','sent','overdue','partially_paid','paid'))),0)
  into deposit_excl,deposit_tax,deposit_incl,previous_deduction
  from related;

  available:=greatest(0,deposit_incl-previous_deduction);
  mode:=coalesce(nullif(target_metadata->>'deposit_deduction_mode',''),
    case when coalesce(target_metadata->>'document_kind','')='progress_invoice' then 'prorata' else 'complete' end);
  if mode not in('complete','prorata','fixed') then
    mode:=case when coalesce(target_metadata->>'document_kind','')='progress_invoice' then 'prorata' else 'complete' end;
  end if;

  if mode='prorata' then
    select coalesce(
      sum(greatest(0,least(100,coalesce(line.cumulative_progress_percent,0)))*greatest(0,source_line.total_excl_tax))/
      nullif(sum(greatest(0,source_line.total_excl_tax))*100,0),0)
    into progress_ratio
    from public.document_lines line
    join public.document_lines source_line on source_line.id=line.source_line_id and source_line.document_id=root_id
    where line.document_id=target.id and line.line_type in('item','free_item','discount') and not line.optional;
    requested:=greatest(0,deposit_incl*least(1,progress_ratio)-previous_deduction);
  elsif mode='fixed' then
    requested:=greatest(0,coalesce(nullif(target_metadata->>'deposit_deduction_fixed_ttc','')::numeric,0));
  else
    requested:=available;
  end if;

  deduction_incl:=round(least(available,greatest(0,gross_incl_tax),requested),2);
  if deposit_incl>0 then
    deduction_excl:=round(least(greatest(0,gross_excl_tax),deduction_incl*deposit_excl/deposit_incl),2);
  end if;
  deduction_tax:=round(greatest(0,deduction_incl-deduction_excl),2);
  if deduction_tax>greatest(0,gross_tax) then
    deduction_tax:=round(greatest(0,gross_tax),2);
    deduction_excl:=round(greatest(0,deduction_incl-deduction_tax),2);
  end if;

  return jsonb_build_object(
    'mode',mode,
    'deposit_total_excl_tax',round(deposit_excl,2),
    'deposit_total_tax',round(deposit_tax,2),
    'deposit_total_incl_tax',round(deposit_incl,2),
    'previous_deduction_incl_tax',round(previous_deduction,2),
    'deduction_excl_tax',deduction_excl,
    'deduction_tax',deduction_tax,
    'deduction_incl_tax',deduction_incl,
    'remaining_deposit_incl_tax',round(greatest(0,available-deduction_incl),2),
    'progress_ratio',round(progress_ratio,6)
  );
end
$$;

create or replace function public.calculate_document_totals()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  raw_cost numeric;
  raw_ht numeric;
  raw_tax numeric;
  ratio numeric;
  gross_ht numeric;
  gross_tax numeric;
  gross_ttc numeric;
  deduction jsonb;
begin
  select coalesce(sum(line.quantity*line.unit_cost_snapshot),0),coalesce(sum(line.total_excl_tax),0),coalesce(sum(line.total_tax),0)
  into raw_cost,raw_ht,raw_tax from public.document_lines line where line.document_id=new.id and not line.optional;
  ratio:=case when raw_ht=0 then 1 else greatest(0,1-new.discount_rate/100) end;
  gross_ht:=round(raw_ht*ratio,2);
  gross_tax:=round(raw_tax*ratio,2);
  gross_ttc:=gross_ht+gross_tax;
  deduction:=public._piloz_document_deposit_deduction(new.id,coalesce(new.metadata,'{}'::jsonb),gross_ht,gross_tax,gross_ttc);
  new.total_cost:=round(raw_cost,2);
  new.total_excl_tax:=round(greatest(0,gross_ht-coalesce((deduction->>'deduction_excl_tax')::numeric,0)),2);
  new.total_tax:=round(greatest(0,gross_tax-coalesce((deduction->>'deduction_tax')::numeric,0)),2);
  new.total_incl_tax:=new.total_excl_tax+new.total_tax;
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)||jsonb_build_object(
    'gross_total_excl_tax',gross_ht,
    'gross_total_tax',gross_tax,
    'gross_total_incl_tax',gross_ttc,
    'deposit_deduction_mode',deduction->>'mode',
    'deposit_deduction_excl_tax',coalesce((deduction->>'deduction_excl_tax')::numeric,0),
    'deposit_deduction_tax',coalesce((deduction->>'deduction_tax')::numeric,0),
    'deposit_deduction_ttc',coalesce((deduction->>'deduction_incl_tax')::numeric,0),
    'deposit_total_ttc',coalesce((deduction->>'deposit_total_incl_tax')::numeric,0),
    'deposit_remaining_ttc',coalesce((deduction->>'remaining_deposit_incl_tax')::numeric,0)
  );
  if new.calculation_version='financial-v2-deposit-deduction' then
    new.calculation_snapshot:=jsonb_build_object(
      'version','financial-v2-deposit-deduction',
      'rounding','half-away-from-zero',
      'rounding_level','line_then_document',
      'gross_total_excl_tax',gross_ht,
      'gross_total_tax',gross_tax,
      'gross_total_incl_tax',gross_ttc,
      'deposit_deduction_mode',deduction->>'mode',
      'deposit_deduction_ttc',coalesce((deduction->>'deduction_incl_tax')::numeric,0)
    );
  end if;
  return new;
end
$$;

create or replace function public.recalculate_document_amounts_v1(target_document_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type<>'quote' and (doc.finalized_at is not null or doc.validated_at is not null or doc.status<>'draft') then
    raise exception 'document_is_locked';
  end if;
  update public.document_lines set
    total_excl_tax=case when line_type in('item','free_item','discount') then round((quantity*unit_price*(1-discount_rate/100))::numeric,2) else 0 end,
    total_tax=case when line_type in('item','free_item','discount') then round((round((quantity*unit_price*(1-discount_rate/100))::numeric,2)*tax_rate/100)::numeric,2) else 0 end,
    total_incl_tax=case when line_type in('item','free_item','discount') then round((quantity*unit_price*(1-discount_rate/100))::numeric,2)+round((round((quantity*unit_price*(1-discount_rate/100))::numeric,2)*tax_rate/100)::numeric,2) else 0 end
  where document_id=doc.id;
  update public.documents set calculation_version='financial-v2-deposit-deduction',calculation_snapshot=jsonb_build_object(
    'version','financial-v2-deposit-deduction','rounding','half-away-from-zero','rounding_level','line_then_document',
    'deposit_deduction_mode',metadata->>'deposit_deduction_mode','deposit_deduction_ttc',coalesce(nullif(metadata->>'deposit_deduction_ttc','')::numeric,0)
  ),updated_at=now() where id=doc.id returning * into doc;
  return jsonb_build_object('total_cost',doc.total_cost,'total_excl_tax',doc.total_excl_tax,
    'total_tax',doc.total_tax,'total_incl_tax',doc.total_incl_tax,'version','financial-v2-deposit-deduction',
    'deposit_deduction_ttc',coalesce(nullif(doc.metadata->>'deposit_deduction_ttc','')::numeric,0));
end
$$;

alter table public.company_fiscal_configurations
  alter column calculation_version set default 'financial-v2-deposit-deduction',
  alter column pdf_generator_version set default 'pdf-v3-cgv';

update public.company_fiscal_configurations set
  application_version='0.9.0-compliance.29',
  schema_version='202607260068',
  calculation_version=case when calculation_version='financial-v1' then 'financial-v2-deposit-deduction' else calculation_version end,
  pdf_generator_version=case when pdf_generator_version='pdf-v2' then 'pdf-v3-cgv' else pdf_generator_version end,
  updated_at=now()
where application_version is distinct from '0.9.0-compliance.29'
   or schema_version is distinct from '202607260068'
   or calculation_version='financial-v1'
   or pdf_generator_version='pdf-v2';

-- Finalization freezes the exact calculation and PDF versions used by this
-- release. Existing finalized documents and snapshots remain untouched.
create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; result_snapshot_id uuid; validation jsonb;
  fiscal_config public.company_fiscal_configurations%rowtype; security_status text; retention_years integer:=10;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then raise exception 'document_type_cannot_be_finalized'; end if;
  if doc.finalized_at is not null then return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',doc.snapshot_id,'pdf_status',doc.pdf_status,'fiscal_security_status',doc.fiscal_security_status); end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null then raise exception 'invalid_document_state'; end if;
  if doc.due_date is null then update public.documents set due_date=case when doc.document_type='credit_note' then doc.issue_date else public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date) end,updated_at=now() where id=doc.id; end if;
  update public.documents set supply_date=coalesce(supply_date,issue_date),operation_category=coalesce(operation_category,nullif(sale_type,''),'goods_and_services'),updated_at=now() where id=doc.id;
  perform public.recalculate_document_amounts_v1(doc.id);
  select * into doc from public.documents where id=doc.id for update;
  validation:=public.validate_invoice_for_finalization(doc.id);
  if not coalesce((validation->>'valid')::boolean,false) then raise exception 'invoice_validation_failed:%',validation->'errors' using errcode='22023'; end if;
  if doc.number is null then update public.documents set number=public._piloz_take_document_number(doc.company_id,doc.document_type,extract(year from coalesce(doc.issue_date,current_date))::integer,false),updated_at=now() where id=doc.id returning * into doc; end if;
  select * into fiscal_config from public.company_fiscal_configurations where company_id=doc.company_id;
  select accounting_retention_years into retention_years from public.company_document_settings where company_id=doc.company_id;
  security_status:=case when fiscal_config.mode='production' and fiscal_config.activation_status='production_active' then 'secured_v1' when fiscal_config.mode='test' and fiscal_config.activation_status='test_active' then 'test_secured' else 'legacy_unsecured' end;
  update public.documents set status='finalized',validated_at=now(),finalized_at=now(),finalized_by=auth.uid(),locked_at=now(),pdf_status='pending',fiscal_security_status=security_status,
    application_version='0.9.0-compliance.29',git_commit=coalesce(fiscal_config.activated_from_commit,'not-recorded'),database_schema_version='202607260068',calculation_version='financial-v2-deposit-deduction',pdf_generator_version='pdf-v3-cgv',electronic_format_version=coalesce(fiscal_config.electronic_format_version,'not-configured'),fiscal_policy_version='fr-invoice-2026-v1',canonicalization_version=coalesce(fiscal_config.canonicalization_version,'jsonb-text-v1'),legal_mentions_snapshot=validation->'mentions',legal_validation_report=validation,
    legal_retention_until=public._piloz_accounting_retention_until(doc.company_id,doc.issue_date,coalesce(retention_years,10)),updated_at=now()
  where id=doc.id returning * into doc;
  result_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set snapshot_id=result_snapshot_id,updated_at=now() where id=doc.id returning * into doc;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by) values(doc.company_id,doc.id,result_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by)) on conflict(snapshot_id) do nothing;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by) values(doc.company_id,auth.uid(),'document.finalized','document',doc.id,jsonb_build_object('number',doc.number,'snapshot_id',result_snapshot_id,'retention_until',doc.legal_retention_until,'validator_version',validation->>'validator_version'),auth.uid());
  perform public._append_fiscal_event(doc.company_id,'invoice_legal_finalized','document',doc.id,clock_timestamp(),jsonb_build_object('number',doc.number,'snapshot_id',result_snapshot_id,'retention_until',doc.legal_retention_until,'validation',validation),'rpc',jsonb_build_object('schema_version','202607260068'));
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status,'fiscal_security_status',doc.fiscal_security_status,'retention_until',doc.legal_retention_until,'validation',validation);
end
$$;

drop function if exists public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb,jsonb
);

create or replace function public.save_document_template_version(
 target_company_id uuid,target_user_id uuid,target_template_id uuid,target_name text,target_document_type text,target_language text,
 target_status text,target_is_default boolean,target_visual_schema jsonb,target_html text,target_css text,target_comment text,
 target_layout_key text default 'classic',target_color_settings jsonb default '{}'::jsonb,target_logo_settings jsonb default '{}'::jsonb,
 target_visible_columns jsonb default '[]'::jsonb,target_header_fields jsonb default '[]'::jsonb,target_footer_id uuid default null,
 target_bank_details_visibility text default 'footer',target_document_title text default null,target_free_field text default null,
 target_client_profile jsonb default '{"show_email":true,"show_phone":true}'::jsonb,target_issuer_profile jsonb default '{}'::jsonb,
 target_payment_methods jsonb default '["bank_transfer"]'::jsonb,target_terms_conditions text default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare template_id uuid; next_version integer;
begin
 if not exists(select 1 from public.company_members where company_id=target_company_id and user_id=target_user_id and role in('owner','admin')) then raise exception 'forbidden' using errcode='42501'; end if;
 if nullif(trim(target_name),'') is null then raise exception 'template_name_required'; end if;
 if char_length(coalesce(target_terms_conditions,''))>30000 then raise exception 'terms_conditions_too_long' using errcode='22023'; end if;
 if target_layout_key not in('classic','modern','compact') then raise exception 'invalid_layout_key'; end if;
 if target_bank_details_visibility not in('hidden','body','summary','footer') then raise exception 'invalid_bank_details_visibility'; end if;
 if target_footer_id is not null and not exists(select 1 from public.document_footers where id=target_footer_id and company_id=target_company_id) then raise exception 'footer_not_found'; end if;
 if target_is_default then update public.document_templates set is_default=false,updated_at=now(),updated_by=target_user_id where company_id=target_company_id and document_type=target_document_type and language=target_language and is_default; end if;
 if target_template_id is null then
  insert into public.document_templates(company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
  values(target_company_id,target_name,target_document_type,target_language,target_status,target_is_default,1,target_user_id,target_user_id)
  returning id,current_version into template_id,next_version;
 else
  select id,current_version+1 into template_id,next_version from public.document_templates where id=target_template_id and company_id=target_company_id for update;
  if template_id is null then raise exception 'template_not_found'; end if;
  update public.document_templates set name=target_name,document_type=target_document_type,language=target_language,status=target_status,is_default=target_is_default,current_version=next_version,updated_by=target_user_id,updated_at=now() where id=template_id;
 end if;
 insert into public.document_template_versions(
   company_id,template_id,version,visual_schema,html,css,change_comment,layout_key,color_settings,logo_settings,
   visible_columns,header_fields,footer_id,bank_details_visibility,document_title,free_field,client_profile,issuer_profile,
   payment_methods,terms_conditions,created_by
 ) values(
   target_company_id,template_id,next_version,coalesce(target_visual_schema,'{}'::jsonb),coalesce(target_html,''),coalesce(target_css,''),
   coalesce(target_comment,'Nouvelle version'),target_layout_key,coalesce(target_color_settings,'{}'::jsonb),
   coalesce(target_logo_settings,'{}'::jsonb),coalesce(target_visible_columns,public._piloz_default_columns()),coalesce(target_header_fields,'[]'::jsonb),
   target_footer_id,target_bank_details_visibility,coalesce(nullif(trim(target_document_title),''),case when target_document_type='quote' then 'Devis' else 'Facture' end),
   nullif(target_free_field,''),coalesce(target_client_profile,'{"show_email":true,"show_phone":true}'::jsonb),coalesce(target_issuer_profile,'{}'::jsonb),
   coalesce(target_payment_methods,'["bank_transfer"]'::jsonb),nullif(target_terms_conditions,''),target_user_id
 );
 return jsonb_build_object('templateId',template_id,'version',next_version);
end
$$;

revoke all on function public._piloz_document_deposit_deduction(uuid,jsonb,numeric,numeric,numeric) from public,anon,authenticated;
revoke all on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb,jsonb,text
) from public;
grant execute on function public.save_document_template_version(
  uuid,uuid,uuid,text,text,text,text,boolean,jsonb,text,text,text,text,jsonb,jsonb,jsonb,jsonb,uuid,text,text,text,jsonb,jsonb,jsonb,text
) to service_role;

commit;
