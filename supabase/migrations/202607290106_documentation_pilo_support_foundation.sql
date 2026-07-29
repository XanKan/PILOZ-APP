begin;

-- Official documentation, Pilo and shared support foundation.
-- Additive only: legacy support_cases remains available during the transition.

insert into public.permission_definitions(
  permission_key,canonical_key,module_key,category_key,category_label,label,description,
  allowed_scopes,sensitive,editor_visible,position
) values
('help.documentation.read','help.documentation.read','help','support','Aide et support','Consulter la documentation','Lire les articles officiels publiés.',array['own','team','company'],false,true,701),
('help.assistant.use','help.assistant.use','help','support','Aide et support','Utiliser Pilo','Interroger la documentation officielle depuis Pilo.',array['own','team','company'],false,true,702),
('support.tickets.create','support.tickets.create','support','support','Aide et support','Créer des tickets','Créer une demande auprès du support Piloz.',array['own','team','company'],false,true,703),
('support.tickets.read_own','support.tickets.read_own','support','support','Aide et support','Consulter ses tickets','Voir ses propres tickets et messages visibles.',array['own'],false,true,704),
('support.tickets.read_company','support.tickets.read_company','support','support','Aide et support','Consulter les tickets de l’entreprise','Voir les tickets de tous les membres de l’entreprise.',array['company'],true,true,705),
('support.tickets.reply','support.tickets.reply','support','support','Aide et support','Répondre aux tickets','Ajouter un message client sur un ticket autorisé.',array['own','company'],false,true,706),
('support.tickets.close','support.tickets.close','support','support','Aide et support','Clore et rouvrir des tickets','Clore ou rouvrir un ticket autorisé.',array['own','company'],false,true,707),
('product.suggestions.create','product.suggestions.create','support','support','Aide et support','Proposer une amélioration','Créer une suggestion produit sans la présenter comme planifiée.',array['own','team','company'],false,true,708),
('product.suggestions.read','product.suggestions.read','support','support','Aide et support','Consulter les suggestions','Consulter les suggestions produit autorisées.',array['own','company'],false,true,709)
on conflict(permission_key) do update set
 canonical_key=excluded.canonical_key,module_key=excluded.module_key,category_key=excluded.category_key,
 category_label=excluded.category_label,label=excluded.label,description=excluded.description,
 allowed_scopes=excluded.allowed_scopes,sensitive=excluded.sensitive,editor_visible=excluded.editor_visible,
 position=excluded.position,active=true,updated_at=now();

-- All active users can access help and create their own support requests.
insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,
 case when permission.permission_key in('support.tickets.read_company') and role.system_key='administrator' then 'company' else 'own' end
from public.company_roles role
cross join (values
 ('help.documentation.read'),('help.assistant.use'),('support.tickets.create'),
 ('support.tickets.read_own'),('support.tickets.reply'),('support.tickets.close'),
 ('product.suggestions.create'),('product.suggestions.read')
) permission(permission_key)
where role.active and role.system_key in('administrator','user','commercial','accountant')
on conflict(role_id,permission_key) do nothing;

insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,'company'
from public.company_roles role
cross join (values('support.tickets.read_company'),('product.suggestions.read')) permission(permission_key)
where role.active and role.system_key='administrator'
on conflict(role_id,permission_key) do update set scope='company',updated_at=now();

create table if not exists public.knowledge_categories(
 id uuid primary key default gen_random_uuid(),
 parent_id uuid references public.knowledge_categories(id) on delete set null,
 slug text not null unique,
 name text not null,
 description text,
 position integer not null default 0,
 active boolean not null default true,
 created_by uuid,
 updated_by uuid,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
);

create table if not exists public.knowledge_articles(
 id uuid primary key default gen_random_uuid(),
 category_id uuid not null references public.knowledge_categories(id) on delete restrict,
 slug text not null unique,
 title text not null,
 summary text not null default '',
 content text not null default '',
 status text not null default 'draft' check(status in('draft','review','published','archived')),
 visibility text not null default 'authenticated' check(visibility in('public','authenticated','company','internal')),
 availability text not null default 'available' check(availability in('available','partial','configuration_required','external_connector_required','roadmap','unavailable')),
 company_id uuid references public.companies(id) on delete cascade,
 language text not null default 'fr' check(language ~ '^[a-z]{2}(?:-[A-Z]{2})?$'),
 app_version_min text,
 app_version_max text,
 current_version integer not null default 1 check(current_version>0),
 search_vector tsvector generated always as (
   setweight(to_tsvector('french',coalesce(title,'')),'A') ||
   setweight(to_tsvector('french',coalesce(summary,'')),'B') ||
   setweight(to_tsvector('french',coalesce(content,'')),'C')
 ) stored,
 published_at timestamptz,
 archived_at timestamptz,
 last_reviewed_at timestamptz,
 created_by uuid,
 updated_by uuid,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check((visibility='company' and company_id is not null) or visibility<>'company'),
 check(status<>'published' or published_at is not null),
 check(slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
);
create index if not exists knowledge_articles_search_idx on public.knowledge_articles using gin(search_vector);
create index if not exists knowledge_articles_publication_idx on public.knowledge_articles(status,language,category_id,published_at desc);
create index if not exists knowledge_articles_company_idx on public.knowledge_articles(company_id,status) where company_id is not null;

create table if not exists public.knowledge_article_versions(
 id uuid primary key default gen_random_uuid(),
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 version_number integer not null check(version_number>0),
 title text not null,
 summary text not null default '',
 content text not null,
 availability text not null check(availability in('available','partial','configuration_required','external_connector_required','roadmap','unavailable')),
 visibility text not null check(visibility in('public','authenticated','company','internal')),
 change_summary text,
 created_by uuid,
 created_at timestamptz not null default now(),
 unique(article_id,version_number)
);

create table if not exists public.knowledge_article_chunks(
 id uuid primary key default gen_random_uuid(),
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 article_version integer not null,
 chunk_index integer not null check(chunk_index>=0),
 heading text,
 content text not null,
 token_count integer,
 search_vector tsvector generated always as (to_tsvector('french',coalesce(heading,'')||' '||coalesce(content,''))) stored,
 created_at timestamptz not null default now(),
 unique(article_id,article_version,chunk_index)
);
create index if not exists knowledge_article_chunks_search_idx on public.knowledge_article_chunks using gin(search_vector);

create table if not exists public.knowledge_tags(
 id uuid primary key default gen_random_uuid(),
 slug text not null unique,
 name text not null unique,
 created_at timestamptz not null default now()
);
create table if not exists public.knowledge_article_tags(
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 tag_id uuid not null references public.knowledge_tags(id) on delete cascade,
 primary key(article_id,tag_id)
);
create table if not exists public.knowledge_article_links(
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 linked_article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 link_type text not null default 'related' check(link_type in('related','prerequisite','next')),
 position integer not null default 0,
 primary key(article_id,linked_article_id,link_type),
 check(article_id<>linked_article_id)
);

create table if not exists public.knowledge_index_events(
 id bigint generated always as identity primary key,
 article_id uuid not null references public.knowledge_articles(id) on delete restrict,
 article_version integer not null,
 event_type text not null check(event_type in('publish','reindex','remove')),
 status text not null default 'pending' check(status in('pending','processing','completed','failed')),
 detail text,
 created_by uuid,
 created_at timestamptz not null default clock_timestamp(),
 completed_at timestamptz
);
create index if not exists knowledge_index_events_queue_idx on public.knowledge_index_events(status,created_at);

create table if not exists public.knowledge_search_events(
 id bigint generated always as identity primary key,
 company_id uuid references public.companies(id) on delete set null,
 user_id uuid,
 query text not null,
 safe_context jsonb not null default '{}'::jsonb,
 result_count integer not null default 0,
 selected_article_id uuid references public.knowledge_articles(id) on delete set null,
 created_at timestamptz not null default clock_timestamp()
);

create table if not exists public.knowledge_article_feedback(
 id uuid primary key default gen_random_uuid(),
 article_id uuid not null references public.knowledge_articles(id) on delete cascade,
 company_id uuid references public.companies(id) on delete set null,
 user_id uuid not null,
 helpful boolean not null,
 comment text,
 safe_context jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(article_id,user_id)
);

create table if not exists public.knowledge_unanswered_questions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid references public.companies(id) on delete set null,
 user_id uuid,
 question text not null,
 normalized_question text not null,
 safe_context jsonb not null default '{}'::jsonb,
 occurrences integer not null default 1 check(occurrences>0),
 status text not null default 'open' check(status in('open','reviewing','documented','dismissed')),
 linked_article_id uuid references public.knowledge_articles(id) on delete set null,
 first_asked_at timestamptz not null default now(),
 last_asked_at timestamptz not null default now(),
 reviewed_by uuid,
 reviewed_at timestamptz
);
create unique index if not exists knowledge_unanswered_unique_open on public.knowledge_unanswered_questions(coalesce(company_id,'00000000-0000-0000-0000-000000000000'::uuid),normalized_question) where status in('open','reviewing');

create table if not exists public.assistant_conversations(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 user_id uuid not null,
 title text,
 safe_context jsonb not null default '{}'::jsonb,
 status text not null default 'open' check(status in('open','closed')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists assistant_conversations_user_idx on public.assistant_conversations(company_id,user_id,updated_at desc);

create table if not exists public.assistant_messages(
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.assistant_conversations(id) on delete cascade,
 role text not null check(role in('user','assistant','system')),
 content text not null,
 answer_level text check(answer_level in('high','medium','low','none')),
 source_article_ids uuid[] not null default '{}',
 safe_context jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists assistant_messages_conversation_idx on public.assistant_messages(conversation_id,created_at,id);

create table if not exists public.assistant_feedback(
 id uuid primary key default gen_random_uuid(),
 message_id uuid not null references public.assistant_messages(id) on delete cascade,
 company_id uuid not null references public.companies(id) on delete cascade,
 user_id uuid not null,
 helpful boolean not null,
 comment text,
 created_at timestamptz not null default now(),
 unique(message_id,user_id)
);

create table if not exists public.support_teams(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 description text,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.support_team_members(
 team_id uuid not null references public.support_teams(id) on delete cascade,
 admin_id uuid not null references public.platform_admins(id) on delete cascade,
 role text not null default 'member' check(role in('manager','member')),
 created_at timestamptz not null default now(),
 primary key(team_id,admin_id)
);

create table if not exists public.support_ticket_counters(
 year integer primary key check(year between 2020 and 2200),
 last_value bigint not null default 0 check(last_value>=0),
 updated_at timestamptz not null default now()
);

create table if not exists public.support_tickets(
 id uuid primary key default gen_random_uuid(),
 ticket_number text not null unique,
 company_id uuid not null references public.companies(id) on delete restrict,
 requester_user_id uuid not null,
 requester_email text,
 subject text not null,
 description text not null,
 category text not null,
 module_key text,
 ticket_type text not null default 'support' check(ticket_type in('support','incident','request','suggestion')),
 priority text not null default 'normal' check(priority in('low','normal','high','urgent')),
 status text not null default 'new' check(status in('new','to_qualify','in_progress','waiting_customer','waiting_internal','resolved','closed','cancelled')),
 safe_context jsonb not null default '{}'::jsonb,
 source text not null default 'app' check(source in('app','pilo','admin','email','api')),
 assigned_team_id uuid references public.support_teams(id) on delete set null,
 assigned_admin_id uuid references public.platform_admins(id) on delete set null,
 first_response_at timestamptz,
 resolved_at timestamptz,
 closed_at timestamptz,
 last_client_message_at timestamptz,
 last_support_message_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(ticket_number ~ '^SUP-[0-9]{4}-[0-9]{6}$')
);
create index if not exists support_tickets_company_idx on public.support_tickets(company_id,updated_at desc,id);
create index if not exists support_tickets_queue_idx on public.support_tickets(status,priority,created_at,id);
create index if not exists support_tickets_requester_idx on public.support_tickets(requester_user_id,updated_at desc);

create table if not exists public.support_ticket_messages(
 id uuid primary key default gen_random_uuid(),
 ticket_id uuid not null references public.support_tickets(id) on delete cascade,
 author_user_id uuid,
 author_admin_id uuid references public.platform_admins(id) on delete set null,
 author_kind text not null check(author_kind in('client','support','system')),
 visibility text not null default 'client' check(visibility in('client','internal','draft')),
 body text not null,
 sent_at timestamptz,
 edited_at timestamptz,
 created_at timestamptz not null default now(),
 check((visibility='draft' and sent_at is null) or (visibility<>'draft' and sent_at is not null)),
 check((author_kind='client' and author_user_id is not null and author_admin_id is null) or author_kind<>'client')
);
create index if not exists support_ticket_messages_thread_idx on public.support_ticket_messages(ticket_id,created_at,id);

create table if not exists public.support_ticket_events(
 id bigint generated always as identity primary key,
 ticket_id uuid not null references public.support_tickets(id) on delete restrict,
 company_id uuid not null references public.companies(id) on delete restrict,
 actor_user_id uuid,
 actor_admin_id uuid references public.platform_admins(id) on delete set null,
 event_type text not null,
 public_summary text,
 internal_detail jsonb,
 created_at timestamptz not null default clock_timestamp()
);
create index if not exists support_ticket_events_ticket_idx on public.support_ticket_events(ticket_id,created_at,id);

create table if not exists public.support_ticket_attachments(
 id uuid primary key default gen_random_uuid(),
 ticket_id uuid not null references public.support_tickets(id) on delete cascade,
 company_id uuid not null references public.companies(id) on delete cascade,
 message_id uuid references public.support_ticket_messages(id) on delete set null,
 uploader_user_id uuid,
 uploader_admin_id uuid references public.platform_admins(id) on delete set null,
 storage_bucket text not null default 'support-ticket-attachments',
 storage_path text not null unique,
 original_name text not null,
 mime_type text not null,
 size_bytes bigint not null check(size_bytes between 1 and 10485760),
 visibility text not null default 'client' check(visibility in('client','internal')),
 created_at timestamptz not null default now()
);
create index if not exists support_ticket_attachments_ticket_idx on public.support_ticket_attachments(ticket_id,created_at);

create table if not exists public.support_ticket_assignments(
 id bigint generated always as identity primary key,
 ticket_id uuid not null references public.support_tickets(id) on delete cascade,
 team_id uuid references public.support_teams(id) on delete set null,
 admin_id uuid references public.platform_admins(id) on delete set null,
 assigned_by uuid references public.platform_admins(id) on delete set null,
 assigned_at timestamptz not null default now(),
 ended_at timestamptz,
 check(team_id is not null or admin_id is not null)
);
create table if not exists public.support_ticket_watchers(
 ticket_id uuid not null references public.support_tickets(id) on delete cascade,
 admin_id uuid not null references public.platform_admins(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(ticket_id,admin_id)
);
create table if not exists public.support_saved_replies(
 id uuid primary key default gen_random_uuid(),
 title text not null,
 body text not null,
 category text,
 active boolean not null default true,
 created_by uuid references public.platform_admins(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.support_sla_policies(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 priority text not null check(priority in('low','normal','high','urgent')),
 first_response_minutes integer not null check(first_response_minutes>0),
 resolution_minutes integer not null check(resolution_minutes>0),
 business_hours jsonb not null default '{}'::jsonb,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.support_ticket_sla_events(
 id bigint generated always as identity primary key,
 ticket_id uuid not null references public.support_tickets(id) on delete cascade,
 policy_id uuid references public.support_sla_policies(id) on delete set null,
 event_type text not null check(event_type in('started','paused','resumed','first_response_met','first_response_breached','resolution_met','resolution_breached')),
 due_at timestamptz,
 created_at timestamptz not null default clock_timestamp()
);

create table if not exists public.product_suggestions(
 id uuid primary key default gen_random_uuid(),
 suggestion_number text not null unique,
 company_id uuid not null references public.companies(id) on delete cascade,
 requester_user_id uuid not null,
 title text not null,
 description text not null,
 module_key text not null default 'roadmap',
 status text not null default 'received' check(status in('received','reviewing','planned','roadmap','rejected','delivered')),
 priority text not null default 'normal' check(priority in('low','normal','high')),
 source_ticket_id uuid references public.support_tickets(id) on delete set null,
 safe_context jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists product_suggestions_company_idx on public.product_suggestions(company_id,updated_at desc);
create table if not exists public.product_suggestion_events(
 id bigint generated always as identity primary key,
 suggestion_id uuid not null references public.product_suggestions(id) on delete cascade,
 actor_user_id uuid,
 actor_admin_id uuid references public.platform_admins(id) on delete set null,
 event_type text not null,
 public_summary text,
 internal_detail jsonb,
 created_at timestamptz not null default clock_timestamp()
);

insert into public.support_teams(name,description) values
 ('Support général','File d’attente principale Piloz'),
 ('Facturation et comptabilité','Devis, factures, règlements, comptabilité et facturation électronique'),
 ('Accès et sécurité','Connexion, utilisateurs, rôles, MFA et sécurité')
on conflict(name) do nothing;
insert into public.support_sla_policies(name,priority,first_response_minutes,resolution_minutes) values
 ('Basse','low',2880,10080),('Normale','normal',1440,4320),('Haute','high',240,1440),('Urgente','urgent',60,480)
on conflict(name) do nothing;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('support-ticket-attachments','support-ticket-attachments',false,10485760,array[
 'application/pdf','image/png','image/jpeg','image/webp','text/plain','text/csv',
 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
]) on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

create or replace function public.sanitize_assistant_context(input_context jsonb)
returns jsonb language sql immutable set search_path=public,pg_temp as $$
 select jsonb_strip_nulls(jsonb_build_object(
  'route',left(nullif(input_context->>'route',''),160),
  'module',left(nullif(input_context->>'module',''),80),
  'submodule',left(nullif(input_context->>'submodule',''),80),
  'object_type',left(nullif(input_context->>'object_type',''),80),
  'object_status',left(nullif(input_context->>'object_status',''),80),
  'technical_id',left(nullif(input_context->>'technical_id',''),80),
  'available_actions',case when jsonb_typeof(input_context->'available_actions')='array' then input_context->'available_actions' else '[]'::jsonb end,
  'role',left(nullif(input_context->>'role',''),80),
  'permissions',case when jsonb_typeof(input_context->'permissions')='array' then input_context->'permissions' else '[]'::jsonb end,
  'language',left(coalesce(nullif(input_context->>'language',''),'fr'),10),
  'app_version',left(nullif(input_context->>'app_version',''),40)
 ));
$$;

create or replace function public.build_safe_assistant_context(input_context jsonb default '{}'::jsonb)
returns jsonb language sql stable security invoker set search_path=public,pg_temp as $$
 select public.sanitize_assistant_context(coalesce(input_context,'{}'::jsonb));
$$;

create or replace function public.can_access_support_ticket(target_ticket_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(
  select 1 from public.support_tickets ticket
  where ticket.id=target_ticket_id
   and public.is_company_member(ticket.company_id)
   and (
    ticket.requester_user_id=auth.uid()
    or public.has_company_permission(ticket.company_id,'support.tickets.read_company')
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
begin
 if auth.uid() is null then raise exception 'Authentification requise' using errcode='42501'; end if;
 if length(normalized_query)<2 then return; end if;
 if target_company_id is not null and public.is_company_member(target_company_id) then allowed_company:=target_company_id; end if;
 return query
 select article.id,article.slug,article.title,article.summary,
  left(regexp_replace(article.content,E'[\\n\\r]+',' ','g'),420),category.name,
  article.availability,article.published_at,
  greatest(ts_rank(article.search_vector,websearch_to_tsquery('french',normalized_query)),
    case when article.title ilike '%'||normalized_query||'%' then 0.8 else 0 end)::real
 from public.knowledge_articles article
 join public.knowledge_categories category on category.id=article.category_id and category.active
 where article.status='published' and article.language='fr'
   and article.visibility in('public','authenticated','company')
   and (article.visibility<>'company' or article.company_id=allowed_company)
   and (article.search_vector @@ websearch_to_tsquery('french',normalized_query)
        or article.title ilike '%'||normalized_query||'%'
        or article.summary ilike '%'||normalized_query||'%')
 order by 10 desc,article.published_at desc nulls last
 limit greatest(1,least(coalesce(result_limit,8),20));
 insert into public.knowledge_search_events(company_id,user_id,query,safe_context,result_count)
 values(allowed_company,auth.uid(),normalized_query,safe,(select count(*) from (
  select 1 from public.knowledge_articles article
  where article.status='published' and article.language='fr'
   and article.visibility in('public','authenticated','company')
   and (article.visibility<>'company' or article.company_id=allowed_company)
   and (article.search_vector @@ websearch_to_tsquery('french',normalized_query)
        or article.title ilike '%'||normalized_query||'%'
        or article.summary ilike '%'||normalized_query||'%') limit 20
 ) found));
end;
$$;

create or replace function public.record_unanswered_pilo_question(
 target_company_id uuid,question_text text,safe_context jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare answer_id uuid; normalized text:=left(lower(regexp_replace(trim(question_text),'\s+',' ','g')),500);
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if length(normalized)<4 then raise exception 'Question trop courte'; end if;
 insert into public.knowledge_unanswered_questions(company_id,user_id,question,normalized_question,safe_context)
 values(target_company_id,auth.uid(),left(trim(question_text),2000),normalized,public.sanitize_assistant_context(safe_context))
 on conflict(coalesce(company_id,'00000000-0000-0000-0000-000000000000'::uuid),normalized_question)
 where status in('open','reviewing') do update set occurrences=public.knowledge_unanswered_questions.occurrences+1,last_asked_at=now()
 returning id into answer_id;
 return answer_id;
end;
$$;

create or replace function public.next_support_ticket_number()
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare current_year integer:=extract(year from current_date)::integer; next_value bigint;
begin
 insert into public.support_ticket_counters(year,last_value) values(current_year,1)
 on conflict(year) do update set last_value=public.support_ticket_counters.last_value+1,updated_at=now()
 returning last_value into next_value;
 return 'SUP-'||current_year::text||'-'||lpad(next_value::text,6,'0');
end;
$$;

create or replace function public.create_support_ticket(
 target_company_id uuid,target_subject text,target_description text,target_category text,
 target_module text default null,target_type text default 'support',target_priority text default 'normal',
 target_context jsonb default '{}'::jsonb,target_source text default 'app'
) returns public.support_tickets language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.support_tickets; current_email text;
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if not public.has_company_permission(target_company_id,'support.tickets.create') then raise exception 'Permission support requise' using errcode='42501'; end if;
 if length(trim(target_subject))<4 or length(trim(target_description))<10 then raise exception 'Le sujet et les détails sont obligatoires'; end if;
 select email into current_email from auth.users where id=auth.uid();
 insert into public.support_tickets(ticket_number,company_id,requester_user_id,requester_email,subject,description,category,module_key,ticket_type,priority,safe_context,source,last_client_message_at)
 values(public.next_support_ticket_number(),target_company_id,auth.uid(),current_email,left(trim(target_subject),200),left(trim(target_description),8000),left(trim(target_category),80),left(trim(target_module),80),target_type,target_priority,public.sanitize_assistant_context(target_context),target_source,now()) returning * into created;
 insert into public.support_ticket_messages(ticket_id,author_user_id,author_kind,visibility,body,sent_at)
 values(created.id,auth.uid(),'client','client',created.description,now());
 insert into public.support_ticket_events(ticket_id,company_id,actor_user_id,event_type,public_summary)
 values(created.id,target_company_id,auth.uid(),'created','Ticket créé');
 return created;
end;
$$;

create or replace function public.add_support_ticket_message(target_ticket_id uuid,message_body text)
returns public.support_ticket_messages language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.support_ticket_messages; target public.support_tickets;
begin
 select * into target from public.support_tickets where id=target_ticket_id for update;
 if target.id is null or not public.can_access_support_ticket(target_ticket_id) then raise exception 'Ticket inaccessible' using errcode='42501'; end if;
 if not public.has_company_permission(target.company_id,'support.tickets.reply') then raise exception 'Permission requise' using errcode='42501'; end if;
 if target.status in('closed','cancelled') then raise exception 'Ce ticket est clos'; end if;
 if length(trim(message_body))<1 then raise exception 'Le message est vide'; end if;
 insert into public.support_ticket_messages(ticket_id,author_user_id,author_kind,visibility,body,sent_at)
 values(target_ticket_id,auth.uid(),'client','client',left(trim(message_body),12000),now()) returning * into created;
 update public.support_tickets set status=case when status='waiting_customer' then 'in_progress' else status end,last_client_message_at=now(),updated_at=now() where id=target_ticket_id;
 insert into public.support_ticket_events(ticket_id,company_id,actor_user_id,event_type,public_summary)
 values(target_ticket_id,target.company_id,auth.uid(),'client_message','Nouveau message du client');
 return created;
end;
$$;

create or replace function public.set_support_ticket_client_status(target_ticket_id uuid,target_status text)
returns public.support_tickets language plpgsql security definer set search_path=public,pg_temp as $$
declare target public.support_tickets;
begin
 select * into target from public.support_tickets where id=target_ticket_id for update;
 if target.id is null or not public.can_access_support_ticket(target_ticket_id) then raise exception 'Ticket inaccessible' using errcode='42501'; end if;
 if not public.has_company_permission(target.company_id,'support.tickets.close') then raise exception 'Permission requise' using errcode='42501'; end if;
 if target_status not in('closed','in_progress') then raise exception 'Statut non autorisé'; end if;
 update public.support_tickets set status=target_status,closed_at=case when target_status='closed' then now() else null end,updated_at=now() where id=target_ticket_id returning * into target;
 insert into public.support_ticket_events(ticket_id,company_id,actor_user_id,event_type,public_summary)
 values(target_ticket_id,target.company_id,auth.uid(),case when target_status='closed' then 'closed_by_client' else 'reopened_by_client' end,case when target_status='closed' then 'Ticket clos par le client' else 'Ticket rouvert par le client' end);
 return target;
end;
$$;

create or replace function public.create_product_suggestion(
 target_company_id uuid,target_title text,target_description text,target_module text default 'roadmap',target_context jsonb default '{}'::jsonb
) returns public.product_suggestions language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.product_suggestions; sequence_value bigint;
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if not public.has_company_permission(target_company_id,'product.suggestions.create') then raise exception 'Permission requise' using errcode='42501'; end if;
 if length(trim(target_title))<4 or length(trim(target_description))<10 then raise exception 'Titre et description obligatoires'; end if;
 sequence_value:=nextval('public.support_ticket_events_id_seq');
 insert into public.product_suggestions(suggestion_number,company_id,requester_user_id,title,description,module_key,safe_context)
 values('IDEA-'||extract(year from current_date)::integer||'-'||lpad(sequence_value::text,6,'0'),target_company_id,auth.uid(),left(trim(target_title),200),left(trim(target_description),8000),left(trim(target_module),80),public.sanitize_assistant_context(target_context)) returning * into created;
 insert into public.product_suggestion_events(suggestion_id,actor_user_id,event_type,public_summary) values(created.id,auth.uid(),'created','Suggestion reçue');
 return created;
end;
$$;

-- Public-client readable views avoid exposing internal support fields.
create or replace view public.support_ticket_client_view with (security_invoker=true) as
select id,ticket_number,company_id,requester_user_id,subject,category,module_key,ticket_type,priority,status,safe_context,source,
 first_response_at,resolved_at,closed_at,last_client_message_at,last_support_message_at,created_at,updated_at
from public.support_tickets;

alter table public.knowledge_categories enable row level security;
alter table public.knowledge_articles enable row level security;
alter table public.knowledge_article_versions enable row level security;
alter table public.knowledge_article_chunks enable row level security;
alter table public.knowledge_tags enable row level security;
alter table public.knowledge_article_tags enable row level security;
alter table public.knowledge_article_links enable row level security;
alter table public.knowledge_index_events enable row level security;
alter table public.knowledge_search_events enable row level security;
alter table public.knowledge_article_feedback enable row level security;
alter table public.knowledge_unanswered_questions enable row level security;
alter table public.assistant_conversations enable row level security;
alter table public.assistant_messages enable row level security;
alter table public.assistant_feedback enable row level security;
alter table public.support_teams enable row level security;
alter table public.support_team_members enable row level security;
alter table public.support_ticket_counters enable row level security;
alter table public.support_tickets enable row level security;
alter table public.support_ticket_messages enable row level security;
alter table public.support_ticket_events enable row level security;
alter table public.support_ticket_attachments enable row level security;
alter table public.support_ticket_assignments enable row level security;
alter table public.support_ticket_watchers enable row level security;
alter table public.support_saved_replies enable row level security;
alter table public.support_sla_policies enable row level security;
alter table public.support_ticket_sla_events enable row level security;
alter table public.product_suggestions enable row level security;
alter table public.product_suggestion_events enable row level security;

create policy knowledge_categories_published_read on public.knowledge_categories for select to authenticated using(active);
create policy knowledge_articles_published_read on public.knowledge_articles for select to authenticated using(
 status='published' and visibility in('public','authenticated','company')
 and (visibility<>'company' or public.is_company_member(company_id))
);
create policy knowledge_versions_published_read on public.knowledge_article_versions for select to authenticated using(
 exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published' and article.current_version=version_number and (article.visibility<>'company' or public.is_company_member(article.company_id)))
);
create policy knowledge_chunks_published_read on public.knowledge_article_chunks for select to authenticated using(
 exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published' and article.current_version=article_version and (article.visibility<>'company' or public.is_company_member(article.company_id)))
);
create policy knowledge_tags_read on public.knowledge_tags for select to authenticated using(true);
create policy knowledge_article_tags_read on public.knowledge_article_tags for select to authenticated using(exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published'));
create policy knowledge_article_links_read on public.knowledge_article_links for select to authenticated using(exists(select 1 from public.knowledge_articles article where article.id=article_id and article.status='published'));
create policy knowledge_feedback_own on public.knowledge_article_feedback for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid() and (company_id is null or public.is_company_member(company_id)));
create policy assistant_conversations_own on public.assistant_conversations for all to authenticated using(user_id=auth.uid() and public.is_company_member(company_id)) with check(user_id=auth.uid() and public.is_company_member(company_id));
create policy assistant_messages_own_read on public.assistant_messages for select to authenticated using(exists(select 1 from public.assistant_conversations conversation where conversation.id=conversation_id and conversation.user_id=auth.uid() and public.is_company_member(conversation.company_id)));
create policy assistant_feedback_own on public.assistant_feedback for all to authenticated using(user_id=auth.uid() and public.is_company_member(company_id)) with check(user_id=auth.uid() and public.is_company_member(company_id));
create policy support_tickets_client_read on public.support_tickets for select to authenticated using(public.can_access_support_ticket(id));
create policy support_messages_client_read on public.support_ticket_messages for select to authenticated using(visibility='client' and sent_at is not null and public.can_access_support_ticket(ticket_id));
create policy support_events_client_read on public.support_ticket_events for select to authenticated using(public_summary is not null and public.can_access_support_ticket(ticket_id));
create policy support_attachments_client_read on public.support_ticket_attachments for select to authenticated using(visibility='client' and public.can_access_support_ticket(ticket_id));
create policy suggestions_client_read on public.product_suggestions for select to authenticated using(public.is_company_member(company_id) and (requester_user_id=auth.uid() or public.has_company_permission(company_id,'product.suggestions.read')));
create policy suggestion_events_client_read on public.product_suggestion_events for select to authenticated using(public_summary is not null and exists(select 1 from public.product_suggestions suggestion where suggestion.id=suggestion_id and public.is_company_member(suggestion.company_id) and (suggestion.requester_user_id=auth.uid() or public.has_company_permission(suggestion.company_id,'product.suggestions.read'))));

-- Immutable client-visible histories. Service/API code only appends.
create or replace function public.reject_history_mutation() returns trigger language plpgsql set search_path=public,pg_temp as $$ begin raise exception 'Historique immuable'; end; $$;
create trigger support_ticket_events_immutable before update or delete on public.support_ticket_events for each row execute function public.reject_history_mutation();
create trigger product_suggestion_events_immutable before update or delete on public.product_suggestion_events for each row execute function public.reject_history_mutation();

revoke all on public.knowledge_categories,public.knowledge_articles,public.knowledge_article_versions,public.knowledge_article_chunks,
 public.knowledge_tags,public.knowledge_article_tags,public.knowledge_article_links,public.knowledge_index_events,
 public.knowledge_search_events,public.knowledge_article_feedback,public.knowledge_unanswered_questions,
 public.assistant_conversations,public.assistant_messages,public.assistant_feedback,
 public.support_teams,public.support_team_members,public.support_ticket_counters,public.support_tickets,
 public.support_ticket_messages,public.support_ticket_events,public.support_ticket_attachments,public.support_ticket_assignments,
 public.support_ticket_watchers,public.support_saved_replies,public.support_sla_policies,public.support_ticket_sla_events,
 public.product_suggestions,public.product_suggestion_events from anon,authenticated;
grant select on public.knowledge_categories,public.knowledge_articles,public.knowledge_article_versions,public.knowledge_article_chunks,
 public.knowledge_tags,public.knowledge_article_tags,public.knowledge_article_links,public.support_ticket_client_view,
 public.support_ticket_messages,public.support_ticket_events,public.support_ticket_attachments,
 public.product_suggestions,public.product_suggestion_events to authenticated;
grant select,insert,update on public.knowledge_article_feedback,public.assistant_conversations,public.assistant_feedback to authenticated;
grant select on public.assistant_messages to authenticated;
grant execute on function public.sanitize_assistant_context(jsonb),public.build_safe_assistant_context(jsonb),
 public.search_piloz_documentation(text,uuid,jsonb,integer),public.record_unanswered_pilo_question(uuid,text,jsonb),
 public.can_access_support_ticket(uuid),public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text),
 public.add_support_ticket_message(uuid,text),public.set_support_ticket_client_status(uuid,text),
 public.create_product_suggestion(uuid,text,text,text,jsonb) to authenticated;
revoke all on function public.next_support_ticket_number() from public,anon,authenticated;

commit;
