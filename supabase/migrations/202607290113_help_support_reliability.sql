begin;

-- Help is available to every active company role. Existing custom roles created
-- before the help module was introduced must not end up with a dead Help area.
insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,'own'
from public.company_roles role
cross join (values
 ('help.documentation.read'),('help.assistant.use'),('support.tickets.create'),
 ('support.tickets.read_own'),('support.tickets.reply'),('support.tickets.close'),
 ('product.suggestions.create'),('product.suggestions.read')
) permission(permission_key)
where role.active
on conflict(role_id,permission_key) do nothing;

-- Module targeting is a relevance hint, not an access boundary. A user asking
-- about invoices from the dashboard must still find the invoice documentation.
-- Role, company, publication state and application-version restrictions remain
-- strict access filters.
create or replace function public.search_piloz_documentation(
 search_query text,
 target_company_id uuid default null,
 safe_context jsonb default '{}'::jsonb,
 result_limit integer default 8
) returns table(
 article_id uuid,slug text,title text,summary text,excerpt text,category_name text,
 availability text,published_at timestamptz,rank real
) language plpgsql security definer set search_path=public,pg_temp as $$
declare
 normalized_query text:=left(trim(coalesce(search_query,'')),500);
 safe jsonb:=public.sanitize_assistant_context(coalesce(safe_context,'{}'::jsonb));
 allowed_company uuid;
 trusted_role text;
 requested_module text:=nullif(left(coalesce(safe->>'module',''),80),'');
 requested_version bigint:=public.piloz_version_number(safe->>'app_version');
 query_terms text[];
 found_count integer:=0;
begin
 if auth.uid() is null then raise exception 'Authentification requise' using errcode='42501'; end if;
 if length(normalized_query)<2 then return; end if;

 select coalesce(array_agg(term),array[]::text[])
 into query_terms
 from (
  select distinct token as term
  from regexp_split_to_table(lower(normalized_query),'[^[:alnum:]]+') token
  where length(token)>=2
 ) terms;

 if target_company_id is not null and public.is_company_member(target_company_id) then
  allowed_company:=target_company_id;
  select coalesce(role.system_key,role.role_key,member.role)
  into trusted_role
  from public.company_members member
  left join public.company_roles role on role.id=member.role_id and role.company_id=member.company_id and role.active
  where member.company_id=allowed_company and member.user_id=auth.uid()
   and coalesce(member.platform_status,'active')='active'
  limit 1;
 end if;

 return query
 with candidates as (
  select article.id,article.slug,article.title,article.summary,
   left(regexp_replace(article.content,E'[\n\r]+',' ','g'),420) as excerpt,
   category.name as category_name,article.availability,article.published_at,
   ts_rank(article.search_vector,websearch_to_tsquery('french',normalized_query)) as full_text_rank,
   coalesce((
    select count(*)::integer
    from unnest(query_terms) term
    where lower(concat_ws(' ',article.title,article.summary,article.content)) like '%'||term||'%'
   ),0) as token_hits,
   exists(
    select 1 from public.knowledge_article_modules module
    where module.article_id=article.id and module.module_key=requested_module
   ) as module_match
  from public.knowledge_articles article
  join public.knowledge_categories category on category.id=article.category_id and category.active
  where article.status='published' and article.language='fr'
   and article.visibility in('public','authenticated','company')
   and (article.visibility<>'company' or article.company_id=allowed_company)
   and (not exists(select 1 from public.knowledge_article_roles restriction where restriction.article_id=article.id)
    or (trusted_role is not null and exists(
     select 1 from public.knowledge_article_roles restriction
     where restriction.article_id=article.id and restriction.role_key=trusted_role
    )))
   and (article.app_version_min is null or requested_version is null or public.piloz_version_number(article.app_version_min)<=requested_version)
   and (article.app_version_max is null or requested_version is null or public.piloz_version_number(article.app_version_max)>=requested_version)
 ), ranked as (
  select candidate.*,
   (greatest(candidate.full_text_rank,
      case when candidate.title ilike '%'||normalized_query||'%' then 0.8 else 0 end,
      case when candidate.summary ilike '%'||normalized_query||'%' then 0.55 else 0 end)
    +least(candidate.token_hits,6)*0.08
    +case when candidate.module_match then 0.12 else 0 end)::real as relevance
  from candidates candidate
  where candidate.full_text_rank>0
   or candidate.title ilike '%'||normalized_query||'%'
   or candidate.summary ilike '%'||normalized_query||'%'
   or candidate.token_hits>0
 )
 select ranked.id,ranked.slug,ranked.title,ranked.summary,ranked.excerpt,ranked.category_name,
  ranked.availability,ranked.published_at,ranked.relevance
 from ranked
 order by ranked.relevance desc,ranked.published_at desc nulls last
 limit greatest(1,least(coalesce(result_limit,8),20));

 get diagnostics found_count=row_count;
 insert into public.knowledge_search_events(company_id,user_id,query,safe_context,result_count)
 values(allowed_company,auth.uid(),normalized_query,safe,found_count);
end;
$$;

grant execute on function public.search_piloz_documentation(text,uuid,jsonb,integer) to authenticated;

commit;
