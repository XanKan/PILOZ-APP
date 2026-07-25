-- Parcours acompte -> facture de solde ou situations, avec récapitulatif du
-- marché figé dans chaque nouveau snapshot. Migration additive et sans
-- modification des factures déjà finalisées.

begin;

create or replace function public._piloz_document_root_quote(target_document_id uuid)
returns uuid
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare target public.documents%rowtype; result_id uuid; metadata_id text;
begin
  select * into target from public.documents where id=target_document_id;
  if target.id is null then return null; end if;
  if target.document_type='quote' then return target.id; end if;
  metadata_id:=target.metadata->>'source_quote_id';
  if metadata_id~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and exists(select 1 from public.documents where id=metadata_id::uuid and company_id=target.company_id and document_type='quote') then
    return metadata_id::uuid;
  end if;
  select source.id into result_id
  from public.document_links link
  join public.documents source on source.id=link.source_document_id and source.company_id=link.company_id
  where link.target_document_id=target.id and link.company_id=target.company_id and source.document_type='quote'
  order by link.created_at limit 1;
  if result_id is not null then return result_id; end if;
  select id into result_id from public.documents
  where id=target.source_document_id and company_id=target.company_id and document_type='quote';
  return result_id;
end
$$;

create or replace function public._piloz_market_summary_json(target_document_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare
  target public.documents%rowtype; quote public.documents%rowtype; root_id uuid;
  rows_payload jsonb:='[]'::jsonb; previous_total numeric:=0;
begin
  select * into target from public.documents where id=target_document_id;
  if target.id is null or target.document_type not in('invoice','deposit_invoice','balance_invoice') then return null; end if;
  root_id:=public._piloz_document_root_quote(target.id);
  select * into quote from public.documents where id=root_id and company_id=target.company_id and document_type='quote';
  if quote.id is null then return null; end if;

  with linked as(
    select distinct document.*
    from public.documents document
    left join public.document_links link on link.target_document_id=document.id
      and link.company_id=document.company_id and link.source_document_id=quote.id
    where document.company_id=quote.company_id and document.id<>target.id
      and document.document_type in('invoice','deposit_invoice','balance_invoice')
      and document.status not in('cancelled','archived')
      and (document.finalized_at is not null or document.validated_at is not null or document.locked_at is not null
        or document.status in('finalized','validated','sent','overdue','partially_paid','paid'))
      and (link.link_type in('invoice','deposit','progress','balance') or document.source_document_id=quote.id)
      and document.created_at<=target.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'document_id',linked.id,'number',coalesce(linked.number,'Brouillon'),
      'document_type',linked.document_type,
      'label',case
        when linked.document_type='deposit_invoice' then 'Facture d''acompte'
        when linked.document_type='balance_invoice' then 'Facture de solde'
        when coalesce(linked.metadata->>'document_kind','')='progress_invoice' then
          'Situation N°'||coalesce(linked.metadata->>'situation_number','1')
        else 'Facture' end,
      'issue_date',linked.issue_date,'total_excl_tax',linked.total_excl_tax,
      'total_tax',linked.total_tax,'total_incl_tax',linked.total_incl_tax
    ) order by linked.issue_date,linked.created_at,linked.id),'[]'::jsonb),
    coalesce(sum(linked.total_incl_tax),0)
  into rows_payload,previous_total from linked;

  return jsonb_build_object(
    'quote_id',quote.id,'quote_number',coalesce(quote.number,'Brouillon'),
    'contract_total_incl_tax',coalesce(quote.total_incl_tax,0),
    'previous_total_incl_tax',previous_total,
    'current_total_incl_tax',coalesce(target.total_incl_tax,0),
    'cumulative_total_incl_tax',previous_total+coalesce(target.total_incl_tax,0),
    'remaining_after_current',greatest(coalesce(quote.total_incl_tax,0)-previous_total-coalesce(target.total_incl_tax,0),0),
    'rows',rows_payload
  );
end
$$;

create or replace function public.get_document_market_summary(target_document_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare target public.documents%rowtype;
begin
  select * into target from public.documents where id=target_document_id;
  if target.id is null or not public.is_company_member(target.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  return public._piloz_market_summary_json(target.id);
end
$$;

create or replace function public.enrich_document_snapshot_market_summary()
returns trigger
language plpgsql
security definer
set search_path=public,extensions,pg_temp
as $$
declare summary jsonb; public_document jsonb; internal_document jsonb;
begin
  summary:=public._piloz_market_summary_json(new.document_id);
  if summary is null then return new; end if;
  public_document:=coalesce(new.public_payload->'document','{}'::jsonb);
  public_document:=jsonb_set(public_document,'{metadata}',coalesce(public_document->'metadata','{}'::jsonb)||jsonb_build_object('market_summary',summary),true);
  new.public_payload:=jsonb_set(jsonb_set(coalesce(new.public_payload,'{}'::jsonb),'{document}',public_document,true),'{market_summary}',summary,true);
  internal_document:=coalesce(new.internal_payload->'document','{}'::jsonb);
  internal_document:=jsonb_set(internal_document,'{metadata}',coalesce(internal_document->'metadata','{}'::jsonb)||jsonb_build_object('market_summary',summary),true);
  new.internal_payload:=jsonb_set(jsonb_set(coalesce(new.internal_payload,'{}'::jsonb),'{document}',internal_document,true),'{market_summary}',summary,true);
  new.payload_hash:=encode(extensions.digest(convert_to(new.public_payload::text,'UTF8'),'sha256'),'hex');
  return new;
end
$$;

drop trigger if exists document_snapshots_market_summary on public.document_snapshots;
create trigger document_snapshots_market_summary
before insert on public.document_snapshots
for each row execute function public.enrich_document_snapshot_market_summary();

create or replace function public.enforce_quote_billing_cap()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare root_id uuid; quote_total numeric; prior_total numeric;
begin
  if new.document_type not in('invoice','deposit_invoice','balance_invoice')
     or (coalesce(old.finalized_at,old.validated_at,old.locked_at) is not null)
     or (coalesce(new.finalized_at,new.validated_at,new.locked_at) is null) then return new; end if;
  root_id:=public._piloz_document_root_quote(new.id);
  if root_id is null then return new; end if;
  select total_incl_tax into quote_total from public.documents where id=root_id and company_id=new.company_id;
  select coalesce(sum(document.total_incl_tax),0) into prior_total
  from public.documents document
  left join public.document_links link on link.target_document_id=document.id and link.company_id=document.company_id
    and link.source_document_id=root_id
  where document.company_id=new.company_id and document.id<>new.id
    and document.document_type in('invoice','deposit_invoice','balance_invoice')
    and document.status not in('cancelled','archived')
    and (document.finalized_at is not null or document.validated_at is not null or document.locked_at is not null
      or document.status in('finalized','validated','sent','overdue','partially_paid','paid'))
    and (link.link_type in('invoice','deposit','progress','balance') or document.source_document_id=root_id);
  if prior_total+coalesce(new.total_incl_tax,0)>coalesce(quote_total,0)+0.01 then
    raise exception 'Le total des factures depasse le montant du devis. Reduisez l avancement ou creez seulement le solde.' using errcode='23514';
  end if;
  return new;
end
$$;

drop trigger if exists documents_quote_billing_cap on public.documents;
create trigger documents_quote_billing_cap
before update of finalized_at,validated_at,locked_at on public.documents
for each row execute function public.enforce_quote_billing_cap();

revoke all on function public._piloz_document_root_quote(uuid) from public,anon,authenticated;
revoke all on function public._piloz_market_summary_json(uuid) from public,anon,authenticated;
revoke all on function public.enrich_document_snapshot_market_summary() from public,anon,authenticated;
revoke all on function public.enforce_quote_billing_cap() from public,anon,authenticated;
revoke all on function public.get_document_market_summary(uuid) from public,anon;
grant execute on function public.get_document_market_summary(uuid) to authenticated;

comment on function public.get_document_market_summary(uuid) is
  'Retourne les factures anterieures du meme devis pour le recapitulatif du marche.';

commit;
