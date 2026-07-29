begin;

-- L'onboarding laisse choisir la présence de l'année et du mois sans rendre
-- modifiables les préfixes métier. Les anciens formats restent compatibles.
alter table public.company_document_settings
  drop constraint if exists company_document_settings_quote_number_format_check;
alter table public.company_document_settings
  add constraint company_document_settings_quote_number_format_check
  check(quote_number_format in('prefix_year_month','prefix_year','prefix_month','prefix_number','year_prefix')) not valid;
alter table public.company_document_settings validate constraint company_document_settings_quote_number_format_check;

alter table public.company_document_settings
  drop constraint if exists company_document_settings_invoice_number_format_check;
alter table public.company_document_settings
  add constraint company_document_settings_invoice_number_format_check
  check(invoice_number_format in('prefix_year_month','prefix_year','prefix_month','prefix_number','year_prefix')) not valid;
alter table public.company_document_settings validate constraint company_document_settings_invoice_number_format_check;

create or replace function public.save_company_numbering_configuration(
  target_company_id uuid,
  target_quote_prefix text,
  target_quote_next_number integer,
  target_quote_format text,
  target_invoice_prefix text,
  target_invoice_next_number integer,
  target_invoice_format text,
  target_credit_prefix text,
  target_quote_validity_days integer
) returns public.company_document_settings
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  current_settings public.company_document_settings%rowtype;
  result public.company_document_settings%rowtype;
  has_quote boolean;
  has_invoice boolean;
  target_year integer:=extract(year from current_date)::integer;
  actor_authorized boolean:=false;
begin
  select exists(
    select 1 from public.companies company
    where company.id=target_company_id and company.owner_user_id=auth.uid()
  ) or exists(
    select 1
    from public.company_members member
    left join public.company_roles role on role.id=member.role_id and role.company_id=member.company_id
    where member.company_id=target_company_id and member.user_id=auth.uid()
      and coalesce(member.platform_status,'active')='active'
      and (member.role in('owner','admin') or role.system_key in('owner','administrator'))
  ) or public.has_company_permission(target_company_id,'company.settings.manage')
  into actor_authorized;
  if not coalesce(actor_authorized,false) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if coalesce(target_quote_next_number,0)<1 or coalesce(target_invoice_next_number,0)<1 then
    raise exception 'document_start_number_invalid' using errcode='22023';
  end if;
  if target_quote_format not in('prefix_year_month','prefix_year','prefix_month','prefix_number','year_prefix')
     or target_invoice_format not in('prefix_year_month','prefix_year','prefix_month','prefix_number','year_prefix') then
    raise exception 'document_number_format_invalid' using errcode='22023';
  end if;
  if upper(trim(coalesce(target_quote_prefix,'')))!~'^[A-Z0-9]{1,10}$'
     or upper(trim(coalesce(target_invoice_prefix,'')))!~'^[A-Z0-9]{1,10}$'
     or upper(trim(coalesce(target_credit_prefix,'')))!~'^[A-Z0-9]{1,10}$' then
    raise exception 'document_prefix_invalid' using errcode='22023';
  end if;

  insert into public.company_document_settings(company_id)
  values(target_company_id) on conflict(company_id) do nothing;
  select * into current_settings
  from public.company_document_settings where company_id=target_company_id for update;
  select exists(
    select 1 from public.documents where company_id=target_company_id and document_type='quote'
  ) into has_quote;
  select exists(
    select 1 from public.documents
    where company_id=target_company_id
      and document_type in('invoice','deposit_invoice','balance_invoice','progress_invoice','credit_note')
  ) into has_invoice;

  if has_quote and (current_settings.quote_prefix is distinct from upper(trim(target_quote_prefix))
     or current_settings.quote_next_number is distinct from target_quote_next_number
     or current_settings.quote_number_format is distinct from target_quote_format) then
    raise exception 'quote_numbering_locked' using errcode='55000';
  end if;
  if has_invoice and (current_settings.invoice_prefix is distinct from upper(trim(target_invoice_prefix))
     or current_settings.invoice_next_number is distinct from target_invoice_next_number
     or current_settings.invoice_number_format is distinct from target_invoice_format) then
    raise exception 'invoice_numbering_locked' using errcode='55000';
  end if;

  update public.company_document_settings set
    quote_prefix=upper(trim(target_quote_prefix)),
    quote_next_number=target_quote_next_number,
    quote_number_format=target_quote_format,
    invoice_prefix=upper(trim(target_invoice_prefix)),
    invoice_next_number=target_invoice_next_number,
    invoice_number_format=target_invoice_format,
    credit_prefix=upper(trim(target_credit_prefix)),
    quote_validity_days=greatest(1,coalesce(target_quote_validity_days,30)),
    numbering_configured_at=coalesce(numbering_configured_at,now()),
    updated_at=now()
  where company_id=target_company_id returning * into result;

  if not has_quote then
    insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
    values(target_company_id,public._piloz_document_sequence_key('quote'),result.quote_prefix,target_year,result.quote_next_number,4,auth.uid())
    on conflict(company_id,document_type,year) do update set
      prefix=excluded.prefix,next_value=excluded.next_value,padding=excluded.padding,updated_at=now();
  end if;
  if not has_invoice then
    insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
    values(target_company_id,public._piloz_document_sequence_key('invoice'),result.invoice_prefix,target_year,result.invoice_next_number,4,auth.uid())
    on conflict(company_id,document_type,year) do update set
      prefix=excluded.prefix,next_value=excluded.next_value,padding=excluded.padding,updated_at=now();
  end if;
  return result;
end $$;

-- Une seule opération atomique remplace les écritures directes de l'onboarding
-- sur des tables RLS différentes.
create or replace function public.save_company_onboarding_document_configuration(
  target_company_id uuid,
  target_quote_next_number integer,
  target_quote_format text,
  target_invoice_next_number integer,
  target_invoice_format text,
  target_credit_next_number integer,
  target_quote_validity_days integer,
  target_default_payment_terms text,
  target_default_payment_method text,
  target_document_language text
) returns public.company_document_settings
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  result public.company_document_settings%rowtype;
begin
  perform public.save_company_numbering_configuration(
    target_company_id,
    'DEV',target_quote_next_number,target_quote_format,
    'FAC',target_invoice_next_number,target_invoice_format,
    'AV',target_quote_validity_days
  );
  update public.company_document_settings set
    credit_prefix='AV',
    credit_next_number=greatest(1,coalesce(target_credit_next_number,1)),
    order_prefix='CMD',
    default_payment_terms=nullif(trim(target_default_payment_terms),''),
    default_payment_method=nullif(trim(target_default_payment_method),''),
    accepted_payment_methods=jsonb_build_array(coalesce(nullif(trim(target_default_payment_method),''),'bank_transfer')),
    document_language=coalesce(nullif(lower(trim(target_document_language)),''),'fr'),
    updated_at=now()
  where company_id=target_company_id returning * into result;
  return result;
end $$;

-- Génération compatible avec les quatre combinaisons année/mois. Sans année,
-- le compteur reste continu entre les exercices afin de préserver l'unicité.
create or replace function public._piloz_take_document_number(
  target_company_id uuid,target_type text,target_year integer,is_draft boolean default false
) returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare
  sequence_key text;
  sequence_row public.document_sequences%rowtype;
  desired_prefix text;
  configured_next integer:=1;
  number_format text:='prefix_year_month';
  number_value text;
  target_month text;
  existing_max bigint:=0;
begin
  if target_company_id is null or target_year not between 2000 and 2200 then
    raise exception 'invalid_document_sequence';
  end if;
  sequence_key:=case when is_draft then 'draft:' else '' end||public._piloz_document_sequence_key(target_type);
  desired_prefix:=public._piloz_document_prefix(target_company_id,target_type,is_draft);
  if not is_draft then
    select
      case
        when target_type='quote' then quote_next_number
        when target_type='credit_note' then credit_next_number
        when target_type in('invoice','deposit_invoice','balance_invoice','progress_invoice') then invoice_next_number
        else 1
      end,
      case
        when target_type='quote' then quote_number_format
        when target_type in('invoice','deposit_invoice','balance_invoice','progress_invoice','credit_note') then invoice_number_format
        else 'prefix_year'
      end
    into configured_next,number_format
    from public.company_document_settings where company_id=target_company_id;

    if number_format in('prefix_number','prefix_month') then
      select coalesce(max((substring(document.number from '([0-9]+)$'))::bigint),0)
      into existing_max
      from public.documents document
      where document.company_id=target_company_id
        and document.number is not null
        and document.number~'[0-9]+$'
        and document.number!~*'^(BROUILLON|BR)-'
        and case public._piloz_document_sequence_key(target_type)
          when 'quote' then document.document_type='quote'
          when 'invoice' then document.document_type in('invoice','deposit_invoice','balance_invoice','progress_invoice')
          when 'credit_note' then document.document_type='credit_note'
          else document.document_type=target_type
        end;
    else
      existing_max:=public._piloz_existing_document_sequence_max(
        target_company_id,public._piloz_document_sequence_key(target_type),target_year
      );
    end if;
    configured_next:=greatest(coalesce(configured_next,1),existing_max+1);
  end if;

  insert into public.document_sequences(company_id,document_type,prefix,year,next_value,padding,created_by)
  values(target_company_id,sequence_key,desired_prefix,target_year,greatest(1,coalesce(configured_next,1)),4,
    coalesce(auth.uid(),(select owner_user_id from public.companies where id=target_company_id)))
  on conflict(company_id,document_type,year) do nothing;
  select * into sequence_row from public.document_sequences
  where company_id=target_company_id and document_type=sequence_key and year=target_year for update;
  if sequence_row.id is null then raise exception 'document_sequence_unavailable'; end if;
  if not is_draft and sequence_row.next_value<=existing_max then
    update public.document_sequences set next_value=existing_max+1,updated_at=now()
    where id=sequence_row.id returning * into sequence_row;
  end if;
  if sequence_row.next_value=greatest(1,coalesce(configured_next,1))
     and sequence_row.prefix is distinct from desired_prefix then
    update public.document_sequences set prefix=desired_prefix,updated_at=now()
    where id=sequence_row.id returning * into sequence_row;
  end if;
  update public.document_sequences set next_value=next_value+1,updated_at=now() where id=sequence_row.id;
  if not is_draft then
    update public.company_document_settings set
      quote_next_number=case when target_type='quote' then sequence_row.next_value+1 else quote_next_number end,
      invoice_next_number=case when target_type in('invoice','deposit_invoice','balance_invoice','progress_invoice') then sequence_row.next_value+1 else invoice_next_number end,
      credit_next_number=case when target_type='credit_note' then sequence_row.next_value+1 else credit_next_number end,
      updated_at=now()
    where company_id=target_company_id;
  end if;
  number_value:=lpad(sequence_row.next_value::text,sequence_row.padding,'0');
  target_month:=lpad(extract(month from current_date)::integer::text,2,'0');
  return case number_format
    when 'prefix_year_month' then sequence_row.prefix||'-'||target_year||'-'||target_month||'-'||number_value
    when 'prefix_year' then sequence_row.prefix||'-'||target_year||'-'||number_value
    when 'prefix_month' then sequence_row.prefix||'-'||target_month||'-'||number_value
    when 'prefix_number' then sequence_row.prefix||'-'||number_value
    when 'year_prefix' then target_year||'-'||sequence_row.prefix||'-'||number_value
    else sequence_row.prefix||'-'||target_year||'-'||number_value
  end;
end $$;

revoke all on function public.save_company_numbering_configuration(uuid,text,integer,text,text,integer,text,text,integer) from public,anon;
grant execute on function public.save_company_numbering_configuration(uuid,text,integer,text,text,integer,text,text,integer) to authenticated;
revoke all on function public.save_company_onboarding_document_configuration(uuid,integer,text,integer,text,integer,integer,text,text,text) from public,anon;
grant execute on function public.save_company_onboarding_document_configuration(uuid,integer,text,integer,text,integer,integer,text,text,text) to authenticated;

commit;
