-- Les situations brouillon conservent toutes les lignes du devis source.
-- Les lignes sans nouvel avancement restent a 0 dans cette situation : elles
-- sont modifiables dans l'editeur, visibles sur le PDF et ne participent pas aux montants.

begin;

create or replace function public._piloz_complete_progress_draft_lines(target_link_id uuid)
returns integer
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  source public.documents%rowtype;
  target public.documents%rowtype;
  link_row public.document_links%rowtype;
  current_situation integer;
  inserted_count integer:=0;
begin
  select * into link_row
  from public.document_links
  where id=target_link_id and link_type='progress';
  if link_row.id is null then return 0; end if;

  select * into source from public.documents
  where id=link_row.source_document_id and company_id=link_row.company_id and document_type='quote';
  select * into target from public.documents
  where id=link_row.target_document_id and company_id=link_row.company_id
    and document_type='invoice' and status='draft'
    and metadata->>'document_kind'='progress_invoice';
  if source.id is null or target.id is null then return 0; end if;

  current_situation:=greatest(1,coalesce(nullif(target.metadata->>'situation_number','')::integer,1));

  insert into public.document_lines(
    company_id,document_id,position,line_type,item_id,reference,name,description,quantity,unit,
    unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,source_line_id,
    cumulative_progress_percent,line_metadata,created_by
  )
  select
    target.company_id,target.id,source_line.position,source_line.line_type,source_line.item_id,
    source_line.reference,source_line.name,source_line.description,0,source_line.unit,
    source_line.unit_cost_snapshot,source_line.unit_price,source_line.discount_rate,
    source_line.tax_rate,false,source_line.id,previous.progress_percent,
    jsonb_build_object(
      'previous_progress_percent',previous.progress_percent,
      'progress_delta_percent',0,
      'progress_placeholder',true,
      'original_quantity',source_line.quantity,
      'original_unit_price',source_line.unit_price,
      'source_quote_id',source.id,
      'situation_number',current_situation
    ),coalesce(target.created_by,source.created_by)
  from public.document_lines source_line
  cross join lateral(
    select coalesce(max(previous_line.cumulative_progress_percent),0) progress_percent
    from public.document_links previous_link
    join public.documents previous_document
      on previous_document.id=previous_link.target_document_id
      and previous_document.status not in('cancelled','archived')
      and coalesce(nullif(previous_document.metadata->>'situation_number','')::integer,0)<current_situation
    join public.document_lines previous_line
      on previous_line.document_id=previous_document.id
      and previous_line.source_line_id=source_line.id
    where previous_link.company_id=target.company_id
      and previous_link.source_document_id=source.id
      and previous_link.link_type='progress'
  ) previous
  where source_line.document_id=source.id
    and source_line.line_type in('item','free_item','discount')
    and not source_line.optional
    and not exists(
      select 1 from public.document_lines target_line
      where target_line.document_id=target.id and target_line.source_line_id=source_line.id
    );

  get diagnostics inserted_count=row_count;
  return inserted_count;
end
$$;

revoke all on function public._piloz_complete_progress_draft_lines(uuid) from public,anon,authenticated;

create or replace function public._piloz_complete_progress_draft_lines_trigger()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.link_type='progress' then
    perform public._piloz_complete_progress_draft_lines(new.id);
  end if;
  return new;
end
$$;

revoke all on function public._piloz_complete_progress_draft_lines_trigger() from public,anon,authenticated;

-- Une ligne de situation a 0 reste une vraie ligne du document. Elle est admise
-- uniquement lorsqu'elle provient du devis source et porte le marqueur interne
-- progress_placeholder. Les factures classiques conservent leurs controles stricts.
create or replace function public.validate_invoice_for_finalization(target_document_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; issuer public.company_settings%rowtype; customer public.clients%rowtype;
  invalid_lines integer:=0; errors jsonb:='[]'::jsonb; warnings jsonb:='[]'::jsonb; mentions jsonb;
begin
  select * into doc from public.documents where id=target_document_id;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  select * into issuer from public.company_settings where company_id=doc.company_id;
  select * into customer from public.clients where id=doc.client_id and company_id=doc.company_id and active;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_type','field','document_type'));
  end if;
  if nullif(trim(issuer.legal_name),'') is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_legal_name_required','field','issuer.legal_name')); end if;
  if issuer.siret is null or issuer.siret !~ '^[0-9]{14}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_siret_required','field','issuer.siret')); end if;
  if nullif(trim(issuer.address_line1),'') is null or nullif(trim(issuer.postal_code),'') is null or nullif(trim(issuer.city),'') is null then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','issuer_address_required','field','issuer.address'));
  end if;
  if customer.id is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','client_required','field','client_id'));
  elsif coalesce(nullif(trim(customer.legal_name),''),nullif(trim(concat_ws(' ',customer.first_name,customer.last_name)),'')) is null then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','client_name_required','field','client.name'));
  end if;
  if customer.id is not null and (nullif(trim(customer.address_line_1),'') is null or nullif(trim(customer.postal_code),'') is null or nullif(trim(customer.city),'') is null or nullif(trim(customer.country_code),'') is null) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','client_address_required','field','client.address'));
  end if;
  if doc.issue_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','issue_date_required','field','issue_date')); end if;
  if doc.currency is null or doc.currency !~ '^[A-Z]{3}$' then errors:=errors||jsonb_build_array(jsonb_build_object('code','currency_invalid','field','currency')); end if;
  if doc.document_type<>'credit_note' and doc.due_date is null then errors:=errors||jsonb_build_array(jsonb_build_object('code','due_date_required','field','due_date')); end if;
  if doc.document_type='credit_note' and (doc.source_document_id is null or not exists(
    select 1 from public.documents source where source.id=doc.source_document_id and source.company_id=doc.company_id
      and source.document_type in('invoice','deposit_invoice','balance_invoice') and source.finalized_at is not null
  )) then errors:=errors||jsonb_build_array(jsonb_build_object('code','credit_source_required','field','source_document_id')); end if;
  select count(*) into invalid_lines
  from public.document_lines line
  where line.document_id=doc.id and line.line_type in('item','free_item','discount')
    and (
      line.optional
      or nullif(trim(coalesce(line.name,'')),'') is null
      or (
        line.quantity<=0
        and not (
          doc.metadata->>'document_kind'='progress_invoice'
          and line.source_line_id is not null
          and line.quantity=0
          and coalesce((line.line_metadata->>'progress_placeholder')::boolean,false)
        )
      )
      or line.unit_price<0
      or line.discount_rate not between 0 and 100
      or line.tax_rate not between 0 and 100
    );
  if not exists(
    select 1 from public.document_lines line
    where line.document_id=doc.id and line.line_type in('item','free_item','discount')
      and not line.optional and line.quantity>0
  ) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','document_lines_required','field','lines'));
  elsif invalid_lines>0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','invalid_document_lines','field','lines','count',invalid_lines)); end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then errors:=errors||jsonb_build_array(jsonb_build_object('code','document_total_must_be_positive','field','totals')); end if;
  if issuer.subject_to_vat is false and exists(select 1 from public.document_lines where document_id=doc.id and tax_rate<>0) then
    errors:=errors||jsonb_build_array(jsonb_build_object('code','vat_rate_for_non_vat_company','field','lines.tax_rate'));
  end if;
  if nullif(trim(doc.sale_type),'') is null then warnings:=warnings||jsonb_build_array(jsonb_build_object('code','operation_category_to_confirm','field','sale_type')); end if;
  if customer.kind='company' and customer.country_code='FR' and nullif(trim(customer.siren),'') is null then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','client_siren_required_for_einvoicing','field','client.siren'));
  end if;
  mentions:=public.resolve_required_invoice_mentions(doc.id);
  if exists(select 1 from jsonb_array_elements(mentions) mention where coalesce((mention->>'requires_legal_validation')::boolean,false)) then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('code','legal_mentions_require_validation','field','legal_mentions'));
  end if;
  return jsonb_build_object('valid',jsonb_array_length(errors)=0,'errors',errors,'warnings',warnings,
    'mentions',mentions,'validator_version','invoice-validator-v2-progress-lines');
end
$$;

revoke all on function public.validate_invoice_for_finalization(uuid) from public,anon;
grant execute on function public.validate_invoice_for_finalization(uuid) to authenticated;

drop trigger if exists complete_progress_draft_lines_after_link on public.document_links;
create trigger complete_progress_draft_lines_after_link
after insert on public.document_links
for each row
when(new.link_type='progress')
execute function public._piloz_complete_progress_draft_lines_trigger();

-- Rattrapage non destructif des situations brouillon deja creees.
do $$
declare
  link_row record;
begin
  for link_row in
    select link.id
    from public.document_links link
    join public.documents target on target.id=link.target_document_id
    where link.link_type='progress' and target.status='draft'
      and target.metadata->>'document_kind'='progress_invoice'
  loop
    perform public._piloz_complete_progress_draft_lines(link_row.id);
  end loop;
end
$$;

comment on function public._piloz_complete_progress_draft_lines(uuid) is
  'Complete une situation brouillon avec toutes les lignes du devis source afin que chaque ligne reste modifiable.';

commit;
