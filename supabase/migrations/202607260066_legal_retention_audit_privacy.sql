begin;

-- Consolidation juridique et operationnelle du cycle de facturation.
-- Cette migration ajoute des controles et des registres. Elle ne revendique
-- aucune certification et n'active aucun connecteur externe automatiquement.

alter table public.company_document_settings
  add column if not exists early_payment_discount_notice text not null
    default 'Escompte pour paiement anticipe : neant.',
  add column if not exists late_payment_penalty_notice text not null
    default 'Penalites de retard : trois fois le taux d''interet legal en vigueur.',
  add column if not exists collection_fee_amount numeric(10,2) not null default 40
    check(collection_fee_amount>=40),
  add column if not exists accounting_retention_years integer not null default 10
    check(accounting_retention_years>=10);

alter table public.company_document_settings
  alter column collection_fee_notice set default
    'Indemnite forfaitaire pour frais de recouvrement due en cas de retard de paiement : 40 EUR.';

update public.company_document_settings
set collection_fee_notice=coalesce(nullif(trim(collection_fee_notice),''),
  'Indemnite forfaitaire pour frais de recouvrement due en cas de retard de paiement : 40 EUR.'),
  updated_at=now()
where nullif(trim(collection_fee_notice),'') is null;

alter table public.documents
  add column if not exists legal_validation_report jsonb not null default '{}'::jsonb,
  add column if not exists legal_retention_until date;

alter table public.attachments
  add column if not exists sha256 text,
  add column if not exists evidence_kind text not null default 'supporting_document',
  add column if not exists locked_at timestamptz,
  add column if not exists retention_until date,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='attachments_sha256_check') then
    alter table public.attachments add constraint attachments_sha256_check
      check(sha256 is null or sha256~'^[0-9a-f]{64}$') not valid;
  end if;
end $$;

grant select(early_payment_discount_notice,late_payment_penalty_notice,
  collection_fee_amount,accounting_retention_years)
on public.company_document_settings to authenticated;
grant select(legal_validation_report,legal_retention_until) on public.documents to authenticated;
grant select(sha256,evidence_kind,locked_at,retention_until,metadata) on public.attachments to authenticated;

-- La date de fin de conservation tient compte de la cloture reelle de
-- l'exercice, y compris lorsque l'exercice ne suit pas l'annee civile.
create or replace function public._piloz_accounting_retention_until(
  target_company_id uuid,
  target_issue_date date,
  target_years integer default 10
)
returns date language plpgsql stable security definer set search_path=public,pg_temp as $$
declare raw_start text; start_month integer:=1; start_day integer:=1;
  start_year integer; start_date date; next_start date; max_day integer;
begin
  select fiscal_year_start into raw_start from public.company_settings where company_id=target_company_id;
  if coalesce(raw_start,'')~'^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then
    start_month:=split_part(raw_start,'-',1)::integer;
    start_day:=split_part(raw_start,'-',2)::integer;
  end if;
  start_year:=extract(year from target_issue_date)::integer;
  max_day:=extract(day from (date_trunc('month',make_date(start_year,start_month,1))+interval '1 month - 1 day'))::integer;
  start_date:=make_date(start_year,start_month,least(start_day,max_day));
  if target_issue_date<start_date then
    start_year:=start_year-1;
    max_day:=extract(day from (date_trunc('month',make_date(start_year,start_month,1))+interval '1 month - 1 day'))::integer;
    start_date:=make_date(start_year,start_month,least(start_day,max_day));
  end if;
  max_day:=extract(day from (date_trunc('month',make_date(start_year+1,start_month,1))+interval '1 month - 1 day'))::integer;
  next_start:=make_date(start_year+1,start_month,least(start_day,max_day));
  return ((next_start-1)+make_interval(years=>greatest(coalesce(target_years,10),10)))::date;
end
$$;

-- Les documents et justificatifs deja definitifs sont egalement places sous
-- retention ; aucune donnee historique n'est supprimee ni reecrite.
update public.documents document set legal_retention_until=public._piloz_accounting_retention_until(
  document.company_id,document.issue_date,coalesce(settings.accounting_retention_years,10))
from public.company_document_settings settings
where settings.company_id=document.company_id and document.finalized_at is not null
  and document.legal_retention_until is null;
update public.attachments attachment set
  locked_at=coalesce(attachment.locked_at,document.finalized_at,document.validated_at),
  retention_until=coalesce(attachment.retention_until,document.legal_retention_until)
from public.documents document
where attachment.entity_id=document.id
  and lower(attachment.entity_type) in('document','invoice','quote','credit_note')
  and (document.finalized_at is not null or document.validated_at is not null);

-- save_document_draft transporte ces champs dans metadata afin de conserver
-- une ecriture atomique. Le trigger les projette dans les colonnes canoniques
-- avant la creation du snapshot et du futur flux electronique.
create or replace function public.apply_document_legal_metadata()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare legal_fields jsonb:=coalesce(new.metadata->'legal_fields','{}'::jsonb);
begin
  if new.finalized_at is null and new.validated_at is null then
    new.operation_category:=coalesce(nullif(legal_fields->>'operation_category',''),new.operation_category,nullif(new.sale_type,''),'goods_and_services');
    new.supply_date:=coalesce(nullif(legal_fields->>'supply_date','')::date,new.supply_date,new.issue_date);
    new.contract_reference:=coalesce(nullif(legal_fields->>'contract_reference',''),new.contract_reference);
    new.purchase_order_reference:=coalesce(nullif(legal_fields->>'purchase_order_reference',''),new.purchase_order_reference);
  end if;
  return new;
end
$$;
drop trigger if exists documents_apply_legal_metadata on public.documents;
create trigger documents_apply_legal_metadata before insert or update on public.documents
for each row execute function public.apply_document_legal_metadata();

-- Toutes les factures d'une meme sequence partagent le meme verrou de date.
-- Les factures, acomptes et soldes utilisent la sequence "invoice".
create or replace function public.enforce_invoice_issue_date_chronology()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare latest_issue_date date; sequence_key text;
begin
  if old.finalized_at is not null or new.finalized_at is null
    or new.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    return new;
  end if;
  sequence_key:=public._piloz_document_sequence_key(new.document_type);
  perform pg_advisory_xact_lock(hashtextextended(new.company_id::text||':'||sequence_key,0));
  select max(document.issue_date) into latest_issue_date
  from public.documents document
  where document.company_id=new.company_id and document.id<>new.id
    and public._piloz_document_sequence_key(document.document_type)=sequence_key
    and document.finalized_at is not null;
  if latest_issue_date is not null and new.issue_date<latest_issue_date then
    raise exception 'invoice_issue_date_before_last_finalized:%',latest_issue_date
      using errcode='22023',detail='La date d''emission doit respecter l''ordre chronologique de la serie de numerotation.';
  end if;
  return new;
end
$$;

-- Une facture definitive ne peut plus etre modifiee, y compris depuis une
-- fonction SECURITY DEFINER. Seules les projections non constitutives de la
-- facture (PDF, envoi, paiement, statut electronique) peuvent evoluer.
create or replace function public.protect_final_document_lifecycle()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare allowed_columns text[]:=array[
  'status','updated_at','viewed_at','last_reminder_at','sent_at','last_sent_at','send_count',
  'accepted_at','rejected_at','expired_at','archived_at',
  'snapshot_id','final_pdf_path','final_pdf_sha256','final_pdf_generated_at','pdf_status',
  'electronic_invoice_status','electronic_profile_code','electronic_format','electronic_invoice_record_id',
  'payment_status','paid_amount','balance_due'
];
begin
  if tg_op='DELETE' and (old.finalized_at is not null or old.validated_at is not null) then
    raise exception 'finalized_document_cannot_be_deleted' using errcode='55000';
  end if;
  if tg_op='UPDATE' and (old.finalized_at is not null or old.validated_at is not null)
    and (to_jsonb(new)-allowed_columns) is distinct from (to_jsonb(old)-allowed_columns) then
    raise exception 'finalized_document_is_immutable_create_credit_note' using errcode='55000';
  end if;
  if tg_op='UPDATE' and old.document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
    and (old.finalized_at is not null or old.validated_at is not null)
    and lower(coalesce(new.status,'')) in('draft','cancelled','canceled','void','deleted') then
    raise exception 'finalized_invoice_requires_credit_note' using errcode='55000';
  end if;
  if tg_op='UPDATE' and current_user not in('postgres','service_role','supabase_admin')
    and old.finalized_at is null and old.validated_at is null and (
    new.number is distinct from old.number and new.finalized_at is null
    or new.finalized_at is distinct from old.finalized_at and new.finalized_at is null
  ) then
    raise exception 'document_lifecycle_rpc_required' using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;

-- Les liens constitutifs de la piste d'audit ne sont jamais effaces lorsqu'un
-- des documents concernes est definitif.
create or replace function public.protect_fiscal_document_link()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare source_id uuid; target_id uuid;
begin
  if tg_op='INSERT' then return new; end if;
  source_id:=old.source_document_id; target_id:=old.target_document_id;
  if exists(select 1 from public.documents where id in(source_id,target_id)
    and (finalized_at is not null or validated_at is not null)) then
    raise exception 'fiscal_document_link_is_immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists document_links_protect_fiscal_trace on public.document_links;
create trigger document_links_protect_fiscal_trace before update or delete on public.document_links
for each row execute function public.protect_fiscal_document_link();

-- Une piece justificative rattachee a un document definitif est verrouillee
-- jusqu'au terme de sa conservation legale.
create or replace function public.protect_fiscal_attachment()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare document_id uuid; document_row public.documents%rowtype; years integer:=10;
begin
  document_id:=case when tg_op='DELETE' then old.entity_id else new.entity_id end;
  if lower(case when tg_op='DELETE' then old.entity_type else new.entity_type end) in('document','invoice','quote','credit_note') then
    select * into document_row from public.documents where id=document_id;
  end if;
  if tg_op='INSERT' and document_row.id is not null and document_row.finalized_at is not null then
    select accounting_retention_years into years from public.company_document_settings where company_id=document_row.company_id;
    new.locked_at:=coalesce(new.locked_at,now());
    new.retention_until:=coalesce(new.retention_until,public._piloz_accounting_retention_until(
      document_row.company_id,document_row.issue_date,coalesce(years,10)));
    return new;
  end if;
  if tg_op in('UPDATE','DELETE') and (
    old.locked_at is not null or document_row.finalized_at is not null or document_row.validated_at is not null
  ) then
    raise exception 'fiscal_attachment_is_retained' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists attachments_protect_fiscal_evidence on public.attachments;
create trigger attachments_protect_fiscal_evidence before insert or update or delete on public.attachments
for each row execute function public.protect_fiscal_attachment();

create or replace function public.resolve_required_invoice_mentions(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; issuer public.company_settings%rowtype;
  settings public.company_document_settings%rowtype; source_number text; mentions jsonb:='[]'::jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  select * into settings from public.company_document_settings where company_id=doc.company_id;
  mentions:=mentions||jsonb_build_array(
    jsonb_build_object('code','payment_terms','configured_text',doc.payment_terms,'requires_legal_validation',nullif(trim(doc.payment_terms),'') is null),
    jsonb_build_object('code','early_payment_discount','configured_text',settings.early_payment_discount_notice,'requires_legal_validation',false),
    jsonb_build_object('code','late_payment_penalties','configured_text',settings.late_payment_penalty_notice,'requires_legal_validation',false),
    jsonb_build_object('code','collection_fee','amount',settings.collection_fee_amount,'currency','EUR',
      'configured_text',settings.collection_fee_notice,'requires_legal_validation',false)
  );
  if issuer.subject_to_vat is false then mentions:=mentions||jsonb_build_array(jsonb_build_object(
    'code','vat_exemption','configured_text',nullif(trim(settings.legal_notice),''),
    'requires_legal_validation',nullif(trim(settings.legal_notice),'') is null)); end if;
  if issuer.vat_on_debits then mentions:=mentions||jsonb_build_array(jsonb_build_object(
    'code','vat_on_debits','configured_text','TVA acquittee d''apres les debits','requires_legal_validation',false)); end if;
  if doc.document_type='credit_note' then
    select number into source_number from public.documents where id=doc.source_document_id and company_id=doc.company_id;
    mentions:=mentions||jsonb_build_array(jsonb_build_object('code','credit_note_reference','source_number',source_number,'requires_legal_validation',false));
  end if;
  if doc.document_type='deposit_invoice' then mentions:=mentions||jsonb_build_array(jsonb_build_object(
    'code','deposit_invoice','requires_legal_validation',false)); end if;
  return mentions;
end
$$;

create or replace function public.validate_invoice_for_finalization(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; issuer public.company_settings%rowtype; customer public.clients%rowtype;
  settings public.company_document_settings%rowtype; invalid_lines integer:=0;
  errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; mentions jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  select * into settings from public.company_document_settings where company_id=doc.company_id;
  select * into customer from public.clients where id=doc.client_id and company_id=doc.company_id and active;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_type','field','document_type')); end if;
  if nullif(trim(issuer.legal_name),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_legal_name_required','field','issuer.legal_name')); end if;
  if issuer.siret is null or issuer.siret!~'^[0-9]{14}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_siret_required','field','issuer.siret')); end if;
  if coalesce(nullif(trim(issuer.legal_form),''),nullif(trim(issuer.company_type),''),nullif(trim(issuer.establishment_kind),'')) is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_legal_form_required','field','issuer.legal_form')); end if;
  if nullif(trim(issuer.address_line1),'') is null or nullif(trim(issuer.postal_code),'') is null or nullif(trim(issuer.city),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_address_required','field','issuer.address')); end if;
  if coalesce(issuer.subject_to_vat,false) and nullif(trim(issuer.vat_number),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_vat_number_required','field','issuer.vat_number')); end if;
  if coalesce(issuer.legal_form,'')~*'(SARL|EURL|SAS|SASU|SA|SCA|SCS)' and issuer.social_capital is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_share_capital_required','field','issuer.social_capital')); end if;
  if customer.id is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_required','field','client_id'));
  elsif coalesce(nullif(trim(customer.legal_name),''),nullif(trim(concat_ws(' ',customer.first_name,customer.last_name)),'')) is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_name_required','field','client.name')); end if;
  if customer.id is not null and (nullif(trim(customer.address_line_1),'') is null or nullif(trim(customer.postal_code),'') is null or nullif(trim(customer.city),'') is null or nullif(trim(customer.country_code),'') is null) then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_address_required','field','client.address')); end if;
  if current_date>=date '2026-09-01' and customer.kind='company' and customer.country_code='FR' and nullif(trim(customer.siren),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_siren_required_for_einvoicing','field','client.siren')); end if;
  if doc.issue_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issue_date_required','field','issue_date')); end if;
  if doc.supply_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','supply_date_required','field','supply_date')); end if;
  if doc.document_type<>'credit_note' and doc.due_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','due_date_required','field','due_date')); end if;
  if nullif(trim(doc.payment_terms),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','payment_terms_required','field','payment_terms')); end if;
  if doc.currency is null or doc.currency!~'^[A-Z]{3}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','currency_invalid','field','currency')); end if;
  if coalesce(nullif(trim(doc.operation_category),''),nullif(trim(doc.sale_type),'')) is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','operation_category_required','field','operation_category')); end if;
  if nullif(trim(settings.early_payment_discount_notice),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','early_payment_discount_notice_required','field','settings.early_payment_discount_notice')); end if;
  if nullif(trim(settings.late_payment_penalty_notice),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','late_payment_penalty_notice_required','field','settings.late_payment_penalty_notice')); end if;
  if coalesce(settings.collection_fee_amount,0)<40 or nullif(trim(settings.collection_fee_notice),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','collection_fee_notice_required','field','settings.collection_fee_notice')); end if;
  if doc.document_type='credit_note' and (doc.source_document_id is null or not exists(select 1 from public.documents source where source.id=doc.source_document_id and source.company_id=doc.company_id and source.document_type in('invoice','deposit_invoice','balance_invoice') and source.finalized_at is not null)) then errors:=errors||jsonb_build_array(jsonb_build_object('code','credit_source_required','field','source_document_id')); end if;
  select count(*) into invalid_lines from public.document_lines line where line.document_id=doc.id and line.line_type in('item','free_item','discount') and (
    line.optional or nullif(trim(coalesce(line.name,'')),'') is null or (line.quantity<=0 and not(doc.metadata->>'document_kind'='progress_invoice' and line.source_line_id is not null and line.quantity=0 and coalesce((line.line_metadata->>'progress_placeholder')::boolean,false))) or line.unit_price<0 or line.discount_rate not between 0 and 100 or line.tax_rate not between 0 and 100);
  if not exists(select 1 from public.document_lines line where line.document_id=doc.id and line.line_type in('item','free_item','discount') and not line.optional and line.quantity>0) then errors:=errors||jsonb_build_array(jsonb_build_object('code','document_lines_required','field','lines'));
  elsif invalid_lines>0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_lines','field','lines','count',invalid_lines)); end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','document_total_must_be_positive','field','totals')); end if;
  if issuer.subject_to_vat is false and exists(select 1 from public.document_lines where document_id=doc.id and tax_rate<>0) then errors:=errors||jsonb_build_array(jsonb_build_object('code','vat_rate_for_non_vat_company','field','lines.tax_rate')); end if;
  if customer.kind='company' and customer.country_code='FR' and nullif(trim(customer.siren),'') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','client_siren_required_for_einvoicing','field','client.siren','effective_on','2026-09-01')); end if;
  if nullif(trim(doc.purchase_order_reference),'') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','purchase_order_reference_to_confirm','field','purchase_order_reference')); end if;
  mentions:=public.resolve_required_invoice_mentions(doc.id);
  if exists(select 1 from jsonb_array_elements(mentions) mention where coalesce((mention->>'requires_legal_validation')::boolean,false)) then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','legal_mentions_require_validation','field','legal_mentions')); end if;
  return jsonb_build_object('valid',jsonb_array_length(errors)=0,'errors',errors,'warnings',warnings,'mentions',mentions,'validator_version','invoice-validator-v3-fr-2026');
end
$$;

-- La finalisation fige le rapport de controle et la date minimale de
-- conservation (10 ans apres la fin de l'exercice civil d'emission).
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
    application_version=coalesce(fiscal_config.application_version,'0.9.0-compliance.25'),git_commit=coalesce(fiscal_config.activated_from_commit,'not-recorded'),database_schema_version='202607260066',calculation_version=coalesce(fiscal_config.calculation_version,'financial-v1'),pdf_generator_version=coalesce(fiscal_config.pdf_generator_version,'pdf-v2'),electronic_format_version=coalesce(fiscal_config.electronic_format_version,'not-configured'),fiscal_policy_version='fr-invoice-2026-v1',canonicalization_version=coalesce(fiscal_config.canonicalization_version,'jsonb-text-v1'),legal_mentions_snapshot=validation->'mentions',legal_validation_report=validation,
    legal_retention_until=public._piloz_accounting_retention_until(doc.company_id,doc.issue_date,coalesce(retention_years,10)),updated_at=now()
  where id=doc.id returning * into doc;
  result_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set snapshot_id=result_snapshot_id,updated_at=now() where id=doc.id returning * into doc;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by) values(doc.company_id,doc.id,result_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by)) on conflict(snapshot_id) do nothing;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by) values(doc.company_id,auth.uid(),'document.finalized','document',doc.id,jsonb_build_object('number',doc.number,'snapshot_id',result_snapshot_id,'retention_until',doc.legal_retention_until,'validator_version',validation->>'validator_version'),auth.uid());
  perform public._append_fiscal_event(doc.company_id,'invoice_legal_finalized','document',doc.id,clock_timestamp(),jsonb_build_object('number',doc.number,'snapshot_id',result_snapshot_id,'retention_until',doc.legal_retention_until,'validation',validation),'rpc',jsonb_build_object('schema_version','202607260066'));
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status,'fiscal_security_status',doc.fiscal_security_status,'retention_until',doc.legal_retention_until,'validation',validation);
end
$$;

-- Les champs requis par la facture electronique restent modifiables tant que
-- le document est un brouillon. Ils passent par une RPC afin de conserver les
-- privileges colonne par colonne sur la table documents.
create or replace function public.save_document_legal_fields(
  target_document_id uuid,
  target_operation_category text,
  target_supply_date date,
  target_contract_reference text default null,
  target_purchase_order_reference text default null
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null or doc.finalized_at is not null then
    raise exception 'document_is_locked' using errcode='55000';
  end if;
  if target_operation_category not in('goods','services','goods_and_services') then
    raise exception 'invalid_operation_category' using errcode='22023';
  end if;
  if target_supply_date is null then raise exception 'supply_date_required' using errcode='22023'; end if;
  update public.documents set
    operation_category=target_operation_category,
    supply_date=target_supply_date,
    contract_reference=nullif(trim(target_contract_reference),''),
    purchase_order_reference=nullif(trim(target_purchase_order_reference),''),
    updated_at=now()
  where id=doc.id returning * into doc;
  return jsonb_build_object(
    'id',doc.id,'operation_category',doc.operation_category,'supply_date',doc.supply_date,
    'contract_reference',doc.contract_reference,'purchase_order_reference',doc.purchase_order_reference
  );
end
$$;

-- Registre des obligations de facturation electronique. Une plateforme reste
-- "non prete" tant qu'un connecteur de production valide n'existe pas.
create table if not exists public.company_einvoice_obligations(
  company_id uuid primary key references public.companies(id) on delete restrict,
  company_size text not null default 'unknown' check(company_size in('unknown','large','eti','sme','micro')),
  receive_mandatory_on date not null default date '2026-09-01',
  issue_mandatory_on date,
  selected_platform_name text,
  selected_platform_contract_reference text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
insert into public.company_einvoice_obligations(company_id,issue_mandatory_on)
select id,null from public.companies on conflict(company_id) do nothing;
alter table public.company_einvoice_obligations enable row level security;
drop policy if exists company_einvoice_obligations_select on public.company_einvoice_obligations;
create policy company_einvoice_obligations_select on public.company_einvoice_obligations for select to authenticated using(public.is_company_member(company_id));
revoke all on public.company_einvoice_obligations from anon,authenticated;
grant select on public.company_einvoice_obligations to authenticated;

create or replace function public.configure_einvoice_obligations(target_company_id uuid,target_company_size text,target_platform_name text default null,target_contract_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare row_value public.company_einvoice_obligations%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  if target_company_size not in('unknown','large','eti','sme','micro') then raise exception 'invalid_company_size'; end if;
  insert into public.company_einvoice_obligations(company_id,company_size,issue_mandatory_on,selected_platform_name,selected_platform_contract_reference,updated_by)
  values(target_company_id,target_company_size,case when target_company_size in('large','eti') then date '2026-09-01' when target_company_size in('sme','micro') then date '2027-09-01' else null end,nullif(trim(target_platform_name),''),nullif(trim(target_contract_reference),''),auth.uid())
  on conflict(company_id) do update set company_size=excluded.company_size,issue_mandatory_on=excluded.issue_mandatory_on,selected_platform_name=excluded.selected_platform_name,selected_platform_contract_reference=excluded.selected_platform_contract_reference,updated_by=auth.uid(),updated_at=now() returning * into row_value;
  perform public._append_fiscal_event(target_company_id,'einvoice_obligation_configured','company',target_company_id,clock_timestamp(),to_jsonb(row_value)-array['updated_by']::text[],'rpc','{}'::jsonb);
  return to_jsonb(row_value);
end
$$;

create or replace function public.get_einvoice_readiness(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare obligation public.company_einvoice_obligations%rowtype; connector_count integer; profile_count integer; issuer public.company_settings%rowtype;
begin
  if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
  select * into obligation from public.company_einvoice_obligations where company_id=target_company_id;
  select * into issuer from public.company_settings where company_id=target_company_id;
  select count(*) into connector_count from public.platform_connectors where company_id=target_company_id and connector_kind='accredited_platform' and environment='production' and status='active' and production_enabled and not is_simulation;
  select count(*) into profile_count from public.electronic_format_profiles where validation_status='verified';
  return jsonb_build_object('company_size',coalesce(obligation.company_size,'unknown'),'receive_mandatory_on',coalesce(obligation.receive_mandatory_on,date '2026-09-01'),'issue_mandatory_on',obligation.issue_mandatory_on,'receive_ready',connector_count>0,'issue_ready',connector_count>0 and profile_count>0 and nullif(trim(issuer.electronic_routing_identifier),'') is not null,'production_connector_count',connector_count,'verified_profile_count',profile_count,'routing_identifier_present',nullif(trim(issuer.electronic_routing_identifier),'') is not null,'external_platform_required',true);
end
$$;

-- Registres RGPD : contrats de sous-traitance, mesures de securite et violations.
create table if not exists public.data_processing_agreements(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  processor_name text not null,processor_contact text,processing_scope text not null,data_categories text[] not null default '{}',
  data_subject_categories text[] not null default '{}',security_measures jsonb not null default '{}'::jsonb,
  subprocessor_terms text,international_transfer_basis text,retention_and_deletion_terms text,
  status text not null default 'draft' check(status in('draft','signed','expired','terminated')),
  effective_on date,expires_on date,artifact_path text,artifact_sha256 text,created_by uuid,created_at timestamptz not null default now(),signed_by uuid,signed_at timestamptz,
  check(artifact_sha256 is null or artifact_sha256~'^[0-9a-f]{64}$'),
  check(status<>'signed' or (signed_at is not null and artifact_path is not null and artifact_sha256 is not null))
);
create table if not exists public.company_security_controls(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  control_code text not null,control_name text not null,status text not null default 'not_verified' check(status in('not_verified','implemented','tested','failed','not_applicable')),
  description text,evidence_id uuid references public.company_compliance_evidence(id) on delete restrict,last_tested_at timestamptz,next_test_due_at timestamptz,owner_reference text,updated_by uuid,updated_at timestamptz not null default now(),unique(company_id,control_code)
);
create table if not exists public.personal_data_breaches(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  reference text not null,nature text not null,status text not null default 'detected' check(status in('detected','assessing','contained','notified','closed')),
  risk_level text not null default 'unknown' check(risk_level in('unknown','low','medium','high')),
  detected_at timestamptz not null,occurred_from timestamptz,occurred_until timestamptz,data_categories text[] not null default '{}',
  affected_subject_categories text[] not null default '{}',approximate_subject_count integer,approximate_record_count integer,
  likely_consequences text,measures_taken text,controller_notified_at timestamptz,authority_notification_required boolean,
  authority_deadline_at timestamptz not null,authority_notified_at timestamptz,subjects_notification_required boolean,subjects_notified_at timestamptz,
  dpo_contact text,created_by uuid,created_at timestamptz not null default now(),closed_at timestamptz,unique(company_id,reference)
);
create table if not exists public.personal_data_breach_events(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  breach_id uuid not null references public.personal_data_breaches(id) on delete restrict,event_type text not null,
  previous_status text,new_status text,details jsonb not null default '{}'::jsonb,actor_id uuid,occurred_at timestamptz not null default now()
);

do $$ declare table_name text; begin
  foreach table_name in array array['data_processing_agreements','company_security_controls','personal_data_breaches','personal_data_breach_events'] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format('create policy %I on public.%I for select to authenticated using(public.has_company_permission(company_id,''compliance_view''))',table_name||'_select',table_name);
    execute format('revoke all on public.%I from anon,authenticated',table_name);
    execute format('grant select on public.%I to authenticated',table_name);
  end loop;
end $$;
drop trigger if exists personal_data_breach_events_immutable on public.personal_data_breach_events;
create trigger personal_data_breach_events_immutable before update or delete on public.personal_data_breach_events for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.protect_signed_data_processing_agreement()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_op='DELETE' or old.status='signed' then raise exception 'signed_data_processing_agreement_is_immutable' using errcode='55000'; end if;
  return new;
end
$$;
drop trigger if exists data_processing_agreements_protect_signed on public.data_processing_agreements;
create trigger data_processing_agreements_protect_signed before update or delete on public.data_processing_agreements for each row execute function public.protect_signed_data_processing_agreement();

create or replace function public.save_data_processing_agreement(target_company_id uuid,target_agreement jsonb,target_agreement_id uuid default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id uuid:=coalesce(target_agreement_id,gen_random_uuid()); current_status text;
begin
  if not public.has_company_permission(target_company_id,'personal_data_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(target_agreement->>'processor_name'),'') is null or nullif(trim(target_agreement->>'processing_scope'),'') is null then raise exception 'processor_and_scope_required'; end if;
  if target_agreement_id is not null then
    select status into current_status from public.data_processing_agreements where id=target_agreement_id and company_id=target_company_id;
    if current_status is null then raise exception 'data_processing_agreement_not_found' using errcode='P0002'; end if;
  end if;
  if current_status='signed' then raise exception 'signed_data_processing_agreement_is_immutable' using errcode='55000'; end if;
  insert into public.data_processing_agreements(id,company_id,processor_name,processor_contact,processing_scope,data_categories,data_subject_categories,security_measures,subprocessor_terms,international_transfer_basis,retention_and_deletion_terms,status,effective_on,expires_on,created_by)
  values(result_id,target_company_id,trim(target_agreement->>'processor_name'),nullif(trim(target_agreement->>'processor_contact'),''),trim(target_agreement->>'processing_scope'),coalesce(array(select jsonb_array_elements_text(coalesce(target_agreement->'data_categories','[]'::jsonb))),'{}'),coalesce(array(select jsonb_array_elements_text(coalesce(target_agreement->'data_subject_categories','[]'::jsonb))),'{}'),coalesce(target_agreement->'security_measures','{}'::jsonb),nullif(trim(target_agreement->>'subprocessor_terms'),''),nullif(trim(target_agreement->>'international_transfer_basis'),''),nullif(trim(target_agreement->>'retention_and_deletion_terms'),''),'draft',nullif(target_agreement->>'effective_on','')::date,nullif(target_agreement->>'expires_on','')::date,auth.uid())
  on conflict(id) do update set processor_name=excluded.processor_name,processor_contact=excluded.processor_contact,processing_scope=excluded.processing_scope,data_categories=excluded.data_categories,data_subject_categories=excluded.data_subject_categories,security_measures=excluded.security_measures,subprocessor_terms=excluded.subprocessor_terms,international_transfer_basis=excluded.international_transfer_basis,retention_and_deletion_terms=excluded.retention_and_deletion_terms,effective_on=excluded.effective_on,expires_on=excluded.expires_on;
  return result_id;
end
$$;

create or replace function public.sign_data_processing_agreement(target_agreement_id uuid,target_artifact_path text,target_artifact_sha256 text,target_effective_on date default current_date)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare agreement public.data_processing_agreements%rowtype; normalized_hash text:=lower(trim(target_artifact_sha256));
begin
  select * into agreement from public.data_processing_agreements where id=target_agreement_id for update;
  if agreement.id is null then raise exception 'data_processing_agreement_not_found' using errcode='P0002'; end if;
  if not public.has_company_permission(agreement.company_id,'personal_data_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if agreement.status<>'draft' or nullif(trim(target_artifact_path),'') is null or normalized_hash!~'^[0-9a-f]{64}$' then raise exception 'signed_agreement_artifact_required'; end if;
  update public.data_processing_agreements set status='signed',effective_on=coalesce(target_effective_on,current_date),artifact_path=trim(target_artifact_path),artifact_sha256=normalized_hash,signed_by=auth.uid(),signed_at=now() where id=agreement.id returning * into agreement;
  perform public._append_fiscal_event(agreement.company_id,'data_processing_agreement_signed','data_processing_agreement',agreement.id,clock_timestamp(),jsonb_build_object('processor_name',agreement.processor_name,'artifact_sha256',agreement.artifact_sha256,'effective_on',agreement.effective_on),'rpc','{}'::jsonb);
  return to_jsonb(agreement);
end
$$;

create or replace function public.update_company_security_control(target_company_id uuid,target_control_code text,target_status text,target_evidence_id uuid default null,target_tested_at timestamptz default null,target_next_due_at timestamptz default null,target_owner_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare control public.company_security_controls%rowtype;
begin
  if not public.has_company_permission(target_company_id,'compliance_view') then raise exception 'forbidden' using errcode='42501'; end if;
  if target_status not in('not_verified','implemented','tested','failed','not_applicable') then raise exception 'invalid_security_control_status'; end if;
  update public.company_security_controls set status=target_status,evidence_id=target_evidence_id,last_tested_at=target_tested_at,next_test_due_at=target_next_due_at,owner_reference=nullif(trim(target_owner_reference),''),updated_by=auth.uid(),updated_at=now() where company_id=target_company_id and control_code=target_control_code returning * into control;
  if control.id is null then raise exception 'security_control_not_found' using errcode='P0002'; end if;
  perform public._append_fiscal_event(target_company_id,'security_control_updated','security_control',control.id,clock_timestamp(),jsonb_build_object('control_code',control.control_code,'status',control.status,'evidence_id',control.evidence_id,'last_tested_at',control.last_tested_at,'next_test_due_at',control.next_test_due_at),'rpc','{}'::jsonb);
  return to_jsonb(control);
end
$$;

create or replace function public.record_personal_data_breach(target_company_id uuid,target_nature text,target_detected_at timestamptz default now(),target_risk_level text default 'unknown',target_details jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id uuid:=gen_random_uuid(); reference_value text;
begin
  if not public.has_company_permission(target_company_id,'personal_data_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(target_nature),'') is null then raise exception 'breach_nature_required'; end if;
  if target_risk_level not in('unknown','low','medium','high') then raise exception 'invalid_breach_risk'; end if;
  reference_value:='VIOL-'||to_char(target_detected_at at time zone 'UTC','YYYYMMDD-HH24MISS')||'-'||upper(left(replace(result_id::text,'-',''),6));
  insert into public.personal_data_breaches(id,company_id,reference,nature,risk_level,detected_at,authority_deadline_at,data_categories,affected_subject_categories,likely_consequences,measures_taken,dpo_contact,created_by)
  values(result_id,target_company_id,reference_value,trim(target_nature),target_risk_level,target_detected_at,target_detected_at+interval '72 hours',coalesce(array(select jsonb_array_elements_text(coalesce(target_details->'data_categories','[]'::jsonb))),'{}'),coalesce(array(select jsonb_array_elements_text(coalesce(target_details->'subject_categories','[]'::jsonb))),'{}'),target_details->>'likely_consequences',target_details->>'measures_taken',target_details->>'dpo_contact',auth.uid());
  insert into public.personal_data_breach_events(company_id,breach_id,event_type,new_status,details,actor_id) values(target_company_id,result_id,'breach_recorded','detected',coalesce(target_details,'{}'::jsonb),auth.uid());
  perform public._append_fiscal_event(target_company_id,'personal_data_breach_recorded','personal_data_breach',result_id,target_detected_at,jsonb_build_object('reference',reference_value,'risk_level',target_risk_level,'authority_deadline_at',target_detected_at+interval '72 hours'),'rpc','{}'::jsonb);
  return result_id;
end
$$;

create or replace function public.transition_personal_data_breach(target_breach_id uuid,target_status text,target_details jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare breach public.personal_data_breaches%rowtype; previous text;
begin
  select * into breach from public.personal_data_breaches where id=target_breach_id for update;
  if breach.id is null then raise exception 'personal_data_breach_not_found' using errcode='P0002'; end if;
  if not public.has_company_permission(breach.company_id,'personal_data_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if target_status not in('assessing','contained','notified','closed') then raise exception 'invalid_breach_status'; end if;
  previous:=breach.status;
  update public.personal_data_breaches set status=target_status,risk_level=coalesce(nullif(target_details->>'risk_level',''),risk_level),likely_consequences=coalesce(target_details->>'likely_consequences',likely_consequences),measures_taken=coalesce(target_details->>'measures_taken',measures_taken),authority_notification_required=coalesce((target_details->>'authority_notification_required')::boolean,authority_notification_required),authority_notified_at=coalesce((target_details->>'authority_notified_at')::timestamptz,authority_notified_at),subjects_notification_required=coalesce((target_details->>'subjects_notification_required')::boolean,subjects_notification_required),subjects_notified_at=coalesce((target_details->>'subjects_notified_at')::timestamptz,subjects_notified_at),closed_at=case when target_status='closed' then now() else closed_at end where id=breach.id returning * into breach;
  insert into public.personal_data_breach_events(company_id,breach_id,event_type,previous_status,new_status,details,actor_id) values(breach.company_id,breach.id,'status_changed',previous,target_status,coalesce(target_details,'{}'::jsonb),auth.uid());
  perform public._append_fiscal_event(breach.company_id,'personal_data_breach_status_changed','personal_data_breach',breach.id,clock_timestamp(),jsonb_build_object('reference',breach.reference,'previous_status',previous,'new_status',target_status),'rpc','{}'::jsonb);
  return to_jsonb(breach);
end
$$;

create or replace function public.get_document_audit_trail(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.has_company_permission(doc.company_id,'fiscal_read') then raise exception 'document_not_found' using errcode='P0002'; end if;
  return jsonb_build_object(
    'document',to_jsonb(doc)-array['internal_notes']::text[],
    'links',coalesce((select jsonb_agg(to_jsonb(link) order by link.created_at) from public.document_links link where link.company_id=doc.company_id and (link.source_document_id=doc.id or link.target_document_id=doc.id)),'[]'::jsonb),
    'snapshots',coalesce((select jsonb_agg(to_jsonb(snapshot)-array['payload']::text[] order by snapshot.created_at) from public.document_snapshots snapshot where snapshot.document_id=doc.id),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(payment) order by payment.created_at) from public.payments payment where payment.document_id=doc.id),'[]'::jsonb),
    'attachments',coalesce((select jsonb_agg(to_jsonb(attachment) order by attachment.created_at) from public.attachments attachment where attachment.company_id=doc.company_id and lower(attachment.entity_type) in('document','invoice','quote','credit_note') and attachment.entity_id=doc.id),'[]'::jsonb),
    'fiscal_events',coalesce((select jsonb_agg(to_jsonb(event)-array['payload']::text[] order by event.sequence_number) from public.fiscal_events event where event.company_id=doc.company_id and event.entity_id=doc.id),'[]'::jsonb),
    'electronic_lifecycle',coalesce((select jsonb_agg(to_jsonb(event) order by event.occurred_at) from public.electronic_invoice_lifecycle_events event where event.document_id=doc.id),'[]'::jsonb),
    'integrity',jsonb_build_object('number_allocated',exists(select 1 from public.document_number_allocations allocation where allocation.document_id=doc.id),'snapshot_present',doc.snapshot_id is not null,'pdf_hash_present',doc.final_pdf_sha256 is not null,'retention_until',doc.legal_retention_until)
  );
end
$$;

-- Complete le resume existant sans casser les consommateurs actuels.
alter function public.get_company_compliance_summary(uuid) rename to get_company_compliance_summary_v1;
create or replace function public.get_company_compliance_summary(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  return public.get_company_compliance_summary_v1(target_company_id)||jsonb_build_object(
    'einvoice_readiness',public.get_einvoice_readiness(target_company_id),
    'retained_fiscal_documents',(select count(*) from public.documents where company_id=target_company_id and finalized_at is not null and legal_retention_until>=current_date),
    'fiscal_documents_missing_pdf_hash',(select count(*) from public.documents where company_id=target_company_id and finalized_at is not null and (final_pdf_path is null or final_pdf_sha256 is null)),
    'open_personal_data_breaches',(select count(*) from public.personal_data_breaches where company_id=target_company_id and status<>'closed'),
    'overdue_breach_notifications',(select count(*) from public.personal_data_breaches where company_id=target_company_id and status<>'closed' and authority_notification_required is true and authority_notified_at is null and authority_deadline_at<now()),
    'signed_processing_agreements',(select count(*) from public.data_processing_agreements where company_id=target_company_id and status='signed'),
    'security_controls',coalesce((select jsonb_object_agg(control_code,status) from public.company_security_controls where company_id=target_company_id),'{}'::jsonb)
  );
end
$$;

create or replace function public.seed_company_legal_compliance()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.company_einvoice_obligations(company_id) values(new.id) on conflict(company_id) do nothing;
  insert into public.company_retention_rules(company_id,data_category,retention_months,trigger_event,legal_basis,action_after_expiry,created_by)
  values(new.id,'accounting_supporting_documents',120,'fiscal_year_closed','Obligations comptables et fiscales','review',new.owner_user_id) on conflict(company_id,data_category) do nothing;
  insert into public.company_security_controls(company_id,control_code,control_name,description) values
    (new.id,'access_control','Controle des acces et moindre privilege','Roles, MFA et revues periodiques'),
    (new.id,'encryption','Chiffrement','Chiffrement en transit et au repos a verifier'),
    (new.id,'backup_restore','Sauvegarde et restauration','Test de restauration documente requis'),
    (new.id,'audit_logging','Journalisation','Journal fiscal et journal de securite'),
    (new.id,'incident_response','Gestion des incidents','Procedure de violation et notification sous 72 heures'),
    (new.id,'security_testing','Tests de securite','Revue de vulnerabilite et tests periodiques')
  on conflict(company_id,control_code) do nothing;
  return new;
end
$$;
drop trigger if exists companies_seed_legal_compliance on public.companies;
create trigger companies_seed_legal_compliance after insert on public.companies for each row execute function public.seed_company_legal_compliance();

insert into public.company_retention_rules(company_id,data_category,retention_months,trigger_event,legal_basis,action_after_expiry,created_by)
select company.id,'accounting_supporting_documents',120,'fiscal_year_closed','Obligations comptables et fiscales','review',company.owner_user_id from public.companies company
on conflict(company_id,data_category) do nothing;
insert into public.company_security_controls(company_id,control_code,control_name,description)
select company.id,seed.code,seed.name,seed.description from public.companies company cross join(values
  ('access_control','Controle des acces et moindre privilege','Roles, MFA et revues periodiques'),
  ('encryption','Chiffrement','Chiffrement en transit et au repos a verifier'),
  ('backup_restore','Sauvegarde et restauration','Test de restauration documente requis'),
  ('audit_logging','Journalisation','Journal fiscal et journal de securite'),
  ('incident_response','Gestion des incidents','Procedure de violation et notification sous 72 heures'),
  ('security_testing','Tests de securite','Revue de vulnerabilite et tests periodiques')
) seed(code,name,description) on conflict(company_id,control_code) do nothing;

update public.documents set supply_date=issue_date,operation_category=coalesce(nullif(sale_type,''),'goods_and_services')
where finalized_at is null and document_type in('invoice','deposit_invoice','balance_invoice','credit_note')
  and (supply_date is null or operation_category is null);

revoke all on function public.get_company_compliance_summary_v1(uuid) from public,anon,authenticated;
revoke all on function public._piloz_accounting_retention_until(uuid,date,integer) from public,anon,authenticated;
revoke all on function public.save_document_legal_fields(uuid,text,date,text,text) from public,anon;
revoke all on function public.configure_einvoice_obligations(uuid,text,text,text) from public,anon;
revoke all on function public.get_einvoice_readiness(uuid) from public,anon;
revoke all on function public.record_personal_data_breach(uuid,text,timestamptz,text,jsonb) from public,anon;
revoke all on function public.transition_personal_data_breach(uuid,text,jsonb) from public,anon;
revoke all on function public.save_data_processing_agreement(uuid,jsonb,uuid) from public,anon;
revoke all on function public.sign_data_processing_agreement(uuid,text,text,date) from public,anon;
revoke all on function public.update_company_security_control(uuid,text,text,uuid,timestamptz,timestamptz,text) from public,anon;
revoke all on function public.get_document_audit_trail(uuid) from public,anon;
revoke all on function public.get_company_compliance_summary(uuid) from public,anon;
grant execute on function public.configure_einvoice_obligations(uuid,text,text,text) to authenticated;
grant execute on function public.save_document_legal_fields(uuid,text,date,text,text) to authenticated;
grant execute on function public.get_einvoice_readiness(uuid) to authenticated;
grant execute on function public.record_personal_data_breach(uuid,text,timestamptz,text,jsonb) to authenticated;
grant execute on function public.transition_personal_data_breach(uuid,text,jsonb) to authenticated;
grant execute on function public.save_data_processing_agreement(uuid,jsonb,uuid) to authenticated;
grant execute on function public.sign_data_processing_agreement(uuid,text,text,date) to authenticated;
grant execute on function public.update_company_security_control(uuid,text,text,uuid,timestamptz,timestamptz,text) to authenticated;
grant execute on function public.get_document_audit_trail(uuid) to authenticated;
grant execute on function public.get_company_compliance_summary(uuid) to authenticated;

alter table public.company_fiscal_configurations alter column schema_version set default '202607260066';
update public.company_fiscal_configurations set application_version='0.9.0-compliance.25',schema_version='202607260066',fiscal_policy_version='fr-invoice-2026-v1',updated_at=now();

comment on table public.personal_data_breaches is 'Registre operationnel des violations de donnees, avec echeance de notification et historique immuable.';
comment on function public.get_document_audit_trail(uuid) is 'Piste d audit bidirectionnelle des documents, justificatifs, paiements, snapshots et evenements fiscaux.';
comment on column public.documents.legal_retention_until is 'Date minimale de conservation calculee a la finalisation. Ne declenche aucune suppression automatique.';

commit;
