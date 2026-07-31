-- Contextual activity relations: once a client/prospect is selected, only
-- their contacts, opportunities, quotes and invoices can be linked.
create or replace function public.search_activity_relations_v2(
  target_kind text default 'all',
  target_search text default null,
  target_limit integer default 20,
  target_client_id uuid default null
) returns table(
  entity_type text,
  entity_id uuid,
  label text,
  subtitle text,
  relation_meta jsonb
)
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  context_row record;
  search_value text := trim(coalesce(target_search,''));
  limit_value integer := least(50,greatest(5,coalesce(target_limit,20)));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null
    or not public.has_company_permission(context_row.company_id,'crm.activities.read') then
    raise exception 'activities_forbidden' using errcode='42501';
  end if;
  if length(search_value)<2 and (
    target_client_id is null
    or target_kind not in ('contact','opportunity','document','quote','invoice')
  ) then return; end if;

  return query
  with candidates as (
    select
      case when coalesce(client.relationship_type,'client')='prospect' then 'prospect' else 'client' end entity_type,
      client.id entity_id,
      coalesce(nullif(client.trade_name,''),nullif(client.legal_name,''),nullif(concat_ws(' ',client.first_name,client.last_name),''),'Client') label,
      concat_ws(' · ',nullif(client.city,''),nullif(client.email,''),nullif(client.siret,'')) subtitle,
      jsonb_build_object('relationship_type',client.relationship_type,'client_id',client.id) relation_meta,
      case when lower(coalesce(client.trade_name,client.legal_name,concat_ws(' ',client.first_name,client.last_name))) like lower(search_value)||'%' then 0 else 1 end rank
    from public.clients client
    where client.company_id=context_row.company_id
      and client.active
      and target_kind in('all','client','prospect')
      and (target_kind not in('client','prospect') or coalesce(client.relationship_type,'client')=target_kind)
      and concat_ws(' ',client.trade_name,client.legal_name,client.first_name,client.last_name,client.email,client.phone_e164,client.siren,client.siret,client.city) ilike '%'||search_value||'%'

    union all

    select
      'contact',contact.id,
      coalesce(nullif(concat_ws(' ',contact.first_name,contact.last_name),''),contact.email,'Contact'),
      concat_ws(' · ',client.trade_name,client.legal_name,contact.email,contact.phone_e164),
      jsonb_build_object('client_id',contact.client_id),
      case when lower(concat_ws(' ',contact.first_name,contact.last_name)) like lower(search_value)||'%' then 0 else 1 end
    from public.client_contacts contact
    left join public.clients client on client.id=contact.client_id
    where contact.company_id=context_row.company_id
      and contact.active
      and target_kind in('all','contact')
      and (target_client_id is null or contact.client_id=target_client_id)
      and (search_value='' or concat_ws(' ',contact.first_name,contact.last_name,contact.email,contact.phone_e164) ilike '%'||search_value||'%')

    union all

    select
      'opportunity',opportunity.id,opportunity.name,
      concat_ws(' · ',client.trade_name,client.legal_name,opportunity.stage),
      jsonb_build_object('client_id',opportunity.client_id,'stage',opportunity.stage),
      case when lower(opportunity.name) like lower(search_value)||'%' then 0 else 1 end
    from public.opportunities opportunity
    left join public.clients client on client.id=opportunity.client_id
    where opportunity.company_id=context_row.company_id
      and target_kind in('all','opportunity')
      and (target_client_id is null or opportunity.client_id=target_client_id)
      and (search_value='' or opportunity.name ilike '%'||search_value||'%')

    union all

    select
      case document.document_type when 'quote' then 'quote' else 'invoice' end,
      document.id,coalesce(document.number,'Brouillon'),
      concat_ws(' · ',case document.document_type when 'quote' then 'Devis' else 'Facture' end,document.subject),
      jsonb_build_object('document_type',document.document_type,'client_id',document.client_id),
      case when lower(coalesce(document.number,'')) like lower(search_value)||'%' then 0 else 1 end
    from public.documents document
    where document.company_id=context_row.company_id
      and document.document_type in('quote','invoice')
      and target_kind in('all','document','quote','invoice')
      and (target_client_id is null or document.client_id=target_client_id)
      and (search_value='' or concat_ws(' ',document.number,document.subject) ilike '%'||search_value||'%')
  )
  select candidate.entity_type,candidate.entity_id,candidate.label,candidate.subtitle,candidate.relation_meta
  from candidates candidate
  order by candidate.rank,candidate.label,candidate.entity_id
  limit limit_value;
end
$$;

revoke all on function public.search_activity_relations_v2(text,text,integer,uuid) from public,anon;
grant execute on function public.search_activity_relations_v2(text,text,integer,uuid) to authenticated;

comment on function public.search_activity_relations_v2(text,text,integer,uuid) is
  'Searches activity relations within the current company and optionally scopes contacts, opportunities, quotes and invoices to one client.';
