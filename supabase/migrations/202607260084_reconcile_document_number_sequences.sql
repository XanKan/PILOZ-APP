begin;

-- Reprend la sequence reelle des documents historiques. Une configuration
-- initiale (1/2) ne doit jamais prendre le pas sur un numero deja attribue.
create or replace function public._piloz_existing_document_sequence_max(
  target_company_id uuid,
  target_sequence_key text,
  target_year integer
) returns bigint
language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(max((substring(document.number from '([0-9]+)$'))::bigint),0)
  from public.documents document
  where document.company_id=target_company_id
    and document.number is not null
    and document.number~'[0-9]+$'
    and document.number!~*'^(BROUILLON|BR)-'
    and (
      extract(year from document.issue_date)::integer=target_year
      or document.number like '%-'||target_year::text||'-%'
      or document.number like target_year::text||'-%'
    )
    and case target_sequence_key
      when 'quote' then document.document_type='quote'
      when 'invoice' then document.document_type in('invoice','deposit_invoice','balance_invoice','progress_invoice')
      when 'credit_note' then document.document_type='credit_note'
      else document.document_type=target_sequence_key
    end
$$;

-- Recalage immediat des societes existantes sur le prochain numero reel.
insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
select company.id,'quote',coalesce(nullif(settings.quote_prefix,''),'DEV'),extract(year from current_date)::integer,
       greatest(1,public._piloz_existing_document_sequence_max(company.id,'quote',extract(year from current_date)::integer)+1),
       4,company.owner_user_id
from public.companies company
join public.company_document_settings settings on settings.company_id=company.id
on conflict(company_id,document_type,year) do update set
  next_value=greatest(public.document_sequences.next_value,excluded.next_value),updated_at=now();

insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
select company.id,'invoice',coalesce(nullif(settings.invoice_prefix,''),'FAC'),extract(year from current_date)::integer,
       greatest(1,public._piloz_existing_document_sequence_max(company.id,'invoice',extract(year from current_date)::integer)+1),
       4,company.owner_user_id
from public.companies company
join public.company_document_settings settings on settings.company_id=company.id
on conflict(company_id,document_type,year) do update set
  next_value=greatest(public.document_sequences.next_value,excluded.next_value),updated_at=now();

update public.company_document_settings settings set
  quote_next_number=greatest(settings.quote_next_number,coalesce(sequence.next_value,1)),
  updated_at=now()
from public.document_sequences sequence
where sequence.company_id=settings.company_id and sequence.document_type='quote'
  and sequence.year=extract(year from current_date)::integer;

update public.company_document_settings settings set
  invoice_next_number=greatest(settings.invoice_next_number,coalesce(sequence.next_value,1)),
  updated_at=now()
from public.document_sequences sequence
where sequence.company_id=settings.company_id and sequence.document_type='invoice'
  and sequence.year=extract(year from current_date)::integer;

-- Auto-reparation avant chaque attribution : meme si un import ou une ancienne
-- migration laisse un compteur obsolete, aucun numero existant ne sera repris.
create or replace function public._piloz_take_document_number(
  target_company_id uuid,target_type text,target_year integer,is_draft boolean default false
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare
  sequence_key text;sequence_row public.document_sequences%rowtype;desired_prefix text;
  configured_next integer:=1;number_format text:='prefix_year_month';number_value text;target_month text;
  existing_max bigint:=0;
begin
  if target_company_id is null or target_year not between 2000 and 2200 then raise exception 'invalid_document_sequence';end if;
  sequence_key:=case when is_draft then 'draft:' else '' end||public._piloz_document_sequence_key(target_type);
  desired_prefix:=public._piloz_document_prefix(target_company_id,target_type,is_draft);
  if not is_draft then
    select case when target_type='quote' then quote_next_number when target_type in('invoice','deposit_invoice','balance_invoice') then invoice_next_number else 1 end,
           case when target_type='quote' then quote_number_format when target_type in('invoice','deposit_invoice','balance_invoice') then invoice_number_format else 'prefix_year' end
    into configured_next,number_format from public.company_document_settings where company_id=target_company_id;
    existing_max:=public._piloz_existing_document_sequence_max(target_company_id,public._piloz_document_sequence_key(target_type),target_year);
    configured_next:=greatest(coalesce(configured_next,1),existing_max+1);
  end if;
  insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
  values(target_company_id,sequence_key,desired_prefix,target_year,greatest(1,coalesce(configured_next,1)),4,coalesce(auth.uid(),(select owner_user_id from public.companies where id=target_company_id)))
  on conflict(company_id,document_type,year) do nothing;
  select * into sequence_row from public.document_sequences where company_id=target_company_id and document_type=sequence_key and year=target_year for update;
  if sequence_row.id is null then raise exception 'document_sequence_unavailable';end if;
  if not is_draft and sequence_row.next_value<=existing_max then
    update public.document_sequences set next_value=existing_max+1,updated_at=now() where id=sequence_row.id returning * into sequence_row;
  end if;
  if sequence_row.next_value=greatest(1,coalesce(configured_next,1)) and sequence_row.prefix is distinct from desired_prefix then
    update public.document_sequences set prefix=desired_prefix,updated_at=now() where id=sequence_row.id returning * into sequence_row;
  end if;
  update public.document_sequences set next_value=next_value+1,updated_at=now() where id=sequence_row.id;
  if not is_draft then
    update public.company_document_settings set
      quote_next_number=case when target_type='quote' then sequence_row.next_value+1 else quote_next_number end,
      invoice_next_number=case when target_type in('invoice','deposit_invoice','balance_invoice') then sequence_row.next_value+1 else invoice_next_number end,
      updated_at=now() where company_id=target_company_id;
  end if;
  number_value:=lpad(sequence_row.next_value::text,sequence_row.padding,'0');
  target_month:=lpad(extract(month from current_date)::integer::text,2,'0');
  return case number_format
    when 'prefix_year_month' then sequence_row.prefix||'-'||target_year||'-'||target_month||'-'||number_value
    when 'year_prefix' then target_year||'-'||sequence_row.prefix||'-'||number_value
    else sequence_row.prefix||'-'||target_year||'-'||number_value end;
end $$;

revoke all on function public._piloz_existing_document_sequence_max(uuid,text,integer) from public,anon,authenticated;

commit;
