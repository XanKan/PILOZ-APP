-- Documentation Piloz: ciblage module/rôle, pièces jointes privées et suivi de fraîcheur.
-- Migration additive, sans suppression de contenu existant.

create table if not exists public.knowledge_article_modules(
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 module_key text not null check(module_key ~ '^[a-z0-9_:-]+$'),
 created_at timestamptz not null default now(),
 primary key(article_id,module_key)
);

create table if not exists public.knowledge_article_roles(
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 role_key text not null check(role_key ~ '^[a-z0-9_-]+$'),
 created_at timestamptz not null default now(),
 primary key(article_id,role_key)
);

create table if not exists public.knowledge_article_attachments(
 id uuid primary key default gen_random_uuid(),
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 article_version integer not null check(article_version>0),
 storage_bucket text not null default 'knowledge-article-attachments',
 storage_path text not null unique,
 original_name text not null,
 mime_type text not null,
 size_bytes bigint not null check(size_bytes>0 and size_bytes<=10485760),
 created_by uuid,
 created_at timestamptz not null default now()
);
create index if not exists knowledge_article_attachments_article_idx
 on public.knowledge_article_attachments(article_id,article_version,created_at);

create table if not exists public.knowledge_review_suggestions(
 id uuid primary key default gen_random_uuid(),
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 reason text not null check(reason in('stale','app_version_changed','negative_feedback','unanswered_question')),
 detail text,
 status text not null default 'open' check(status in('open','reviewing','resolved','dismissed')),
 detected_at timestamptz not null default now(),
 reviewed_by uuid,
 reviewed_at timestamptz,
 unique(article_id,reason,status)
);
create index if not exists knowledge_review_suggestions_queue_idx
 on public.knowledge_review_suggestions(status,detected_at desc);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('knowledge-article-attachments','knowledge-article-attachments',false,10485760,array[
 'application/pdf','image/png','image/jpeg','image/webp','text/plain','text/csv',
 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
]) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.piloz_version_number(version_text text)
returns bigint language sql immutable parallel safe set search_path=public,pg_temp as $$
 select case when coalesce(version_text,'') ~ '^\d+(\.\d+){0,2}$' then
   split_part(version_text,'.',1)::bigint*1000000000000
   +coalesce(nullif(split_part(version_text,'.',2),''),'0')::bigint*1000000
   +coalesce(nullif(split_part(version_text,'.',3),''),'0')::bigint
 else null end;
$$;

create or replace function public.can_read_knowledge_article(target_article_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(
  select 1
  from public.knowledge_articles article
  where article.id=target_article_id
    and article.status='published'
    and article.visibility in('public','authenticated','company')
    and (article.visibility<>'company' or public.is_company_member(article.company_id))
    and (
      not exists(select 1 from public.knowledge_article_roles restriction where restriction.article_id=article.id)
      or exists(
        select 1
        from public.company_members member
        left join public.company_roles role on role.id=member.role_id and role.company_id=member.company_id and role.active
        join public.knowledge_article_roles restriction
          on restriction.article_id=article.id
         and restriction.role_key=coalesce(role.system_key,role.role_key,member.role)
        where member.user_id=auth.uid() and coalesce(member.platform_status,'active')='active'
      )
    )
 );
$$;

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
 found_count integer:=0;
begin
 if auth.uid() is null then raise exception 'Authentification requise' using errcode='42501'; end if;
 if length(normalized_query)<2 then return; end if;
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
 select article.id,article.slug,article.title,article.summary,
  left(regexp_replace(article.content,E'[\n\r]+',' ','g'),420),category.name,
  article.availability,article.published_at,
  greatest(ts_rank(article.search_vector,websearch_to_tsquery('french',normalized_query)),
    case when article.title ilike '%'||normalized_query||'%' then 0.8 else 0 end)::real
 from public.knowledge_articles article
 join public.knowledge_categories category on category.id=article.category_id and category.active
 where article.status='published' and article.language='fr'
   and article.visibility in('public','authenticated','company')
   and (article.visibility<>'company' or article.company_id=allowed_company)
   and (not exists(select 1 from public.knowledge_article_modules m where m.article_id=article.id)
        or (requested_module is not null and exists(select 1 from public.knowledge_article_modules m where m.article_id=article.id and m.module_key=requested_module)))
   and (not exists(select 1 from public.knowledge_article_roles r where r.article_id=article.id)
        or (trusted_role is not null and exists(select 1 from public.knowledge_article_roles r where r.article_id=article.id and r.role_key=trusted_role)))
   and (article.app_version_min is null or requested_version is null or public.piloz_version_number(article.app_version_min)<=requested_version)
   and (article.app_version_max is null or requested_version is null or public.piloz_version_number(article.app_version_max)>=requested_version)
   and (article.search_vector @@ websearch_to_tsquery('french',normalized_query)
        or article.title ilike '%'||normalized_query||'%'
        or article.summary ilike '%'||normalized_query||'%')
 order by 9 desc,article.published_at desc nulls last
 limit greatest(1,least(coalesce(result_limit,8),20));

 get diagnostics found_count=row_count;
 insert into public.knowledge_search_events(company_id,user_id,query,safe_context,result_count)
 values(allowed_company,auth.uid(),normalized_query,safe,found_count);
end;
$$;

create or replace function public.refresh_knowledge_review_suggestions(current_app_version text default null)
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare inserted_count integer:=0; new_count integer:=0;
begin
 if auth.uid() is not null and not exists(
   select 1 from public.platform_admins admin where admin.user_id=auth.uid() and admin.status='active'
 ) then raise exception 'Accès administrateur requis' using errcode='42501'; end if;

 insert into public.knowledge_review_suggestions(article_id,reason,detail)
 select article.id,'stale','Article publié non revu depuis plus de 180 jours.'
 from public.knowledge_articles article
 where article.status='published' and coalesce(article.last_reviewed_at,article.published_at,article.updated_at)<now()-interval '180 days'
   and not exists(select 1 from public.knowledge_review_suggestions suggestion where suggestion.article_id=article.id and suggestion.reason='stale' and suggestion.status in('open','reviewing'))
 on conflict do nothing;
 get diagnostics inserted_count=row_count;

 if public.piloz_version_number(current_app_version) is not null then
  insert into public.knowledge_review_suggestions(article_id,reason,detail)
  select article.id,'app_version_changed','La version maximale documentée est antérieure à la version courante.'
  from public.knowledge_articles article
  where article.status='published' and article.app_version_max is not null
    and public.piloz_version_number(article.app_version_max)<public.piloz_version_number(current_app_version)
    and not exists(select 1 from public.knowledge_review_suggestions suggestion where suggestion.article_id=article.id and suggestion.reason='app_version_changed' and suggestion.status in('open','reviewing'))
  on conflict do nothing;
  get diagnostics new_count=row_count;
  inserted_count:=inserted_count+new_count;
 end if;
 return inserted_count;
end;
$$;

create or replace view public.assistant_search_events with (security_invoker=true) as
 select id,company_id,user_id,query,safe_context,result_count,selected_article_id,created_at
 from public.knowledge_search_events;
create or replace view public.assistant_unanswered_questions with (security_invoker=true) as
 select id,company_id,user_id,question,normalized_question,safe_context,occurrences,status,linked_article_id,first_asked_at,last_asked_at,reviewed_by,reviewed_at
 from public.knowledge_unanswered_questions;

alter table public.knowledge_article_modules enable row level security;
alter table public.knowledge_article_roles enable row level security;
alter table public.knowledge_article_attachments enable row level security;
alter table public.knowledge_review_suggestions enable row level security;

drop policy if exists knowledge_articles_published_read on public.knowledge_articles;
create policy knowledge_articles_published_read on public.knowledge_articles for select to authenticated
 using(public.can_read_knowledge_article(id));
drop policy if exists knowledge_versions_published_read on public.knowledge_article_versions;
create policy knowledge_versions_published_read on public.knowledge_article_versions for select to authenticated using(
 public.can_read_knowledge_article(article_id)
 and exists(select 1 from public.knowledge_articles article where article.id=article_id and article.current_version=version_number)
);
drop policy if exists knowledge_chunks_published_read on public.knowledge_article_chunks;
create policy knowledge_chunks_published_read on public.knowledge_article_chunks for select to authenticated using(
 public.can_read_knowledge_article(article_id)
 and exists(select 1 from public.knowledge_articles article where article.id=article_id and article.current_version=article_version)
);

drop policy if exists knowledge_article_modules_published_read on public.knowledge_article_modules;
create policy knowledge_article_modules_published_read on public.knowledge_article_modules for select to authenticated using(
 exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published')
);
drop policy if exists knowledge_article_roles_published_read on public.knowledge_article_roles;
create policy knowledge_article_roles_published_read on public.knowledge_article_roles for select to authenticated using(
 exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published')
);

revoke all on public.knowledge_article_modules,public.knowledge_article_roles,public.knowledge_article_attachments,public.knowledge_review_suggestions from anon,authenticated;
grant select on public.knowledge_article_modules,public.knowledge_article_roles to authenticated;
grant execute on function public.piloz_version_number(text),public.can_read_knowledge_article(uuid),public.search_piloz_documentation(text,uuid,jsonb,integer) to authenticated;
revoke execute on function public.refresh_knowledge_review_suggestions(text) from public,anon,authenticated;

-- Aucun accès direct aux objets privés : les API de confiance fournissent des URL signées de courte durée.
drop policy if exists knowledge_attachments_no_direct_access on storage.objects;
create policy knowledge_attachments_no_direct_access on storage.objects for select to authenticated using(false);
