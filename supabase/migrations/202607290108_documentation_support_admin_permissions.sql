begin;

-- Platform permissions are intentionally separate from client-company roles.
insert into public.platform_admin_permissions(role,permission)
select 'super_admin', permission
from unnest(array[
  'documentation.read','documentation.write','documentation.publish','documentation.index',
  'support.queue','support.reply','support.internal','support.assign','support.settings',
  'suggestions.read','suggestions.write'
]::text[]) permission
on conflict(role,permission) do update set allowed=true;

insert into public.platform_admin_permissions(role,permission)
select 'support_admin', permission
from unnest(array[
  'documentation.read','documentation.write','documentation.publish','documentation.index',
  'support.queue','support.reply','support.internal','support.assign','support.settings',
  'suggestions.read','suggestions.write'
]::text[]) permission
on conflict(role,permission) do update set allowed=true;

insert into public.platform_admin_permissions(role,permission)
select 'read_only_admin', permission
from unnest(array['documentation.read','support.queue','suggestions.read']::text[]) permission
on conflict(role,permission) do update set allowed=true;

create table if not exists public.product_suggestion_counters(
 year integer primary key check(year between 2020 and 2200),
 last_value bigint not null default 0 check(last_value>=0),
 updated_at timestamptz not null default now()
);
alter table public.product_suggestion_counters enable row level security;
revoke all on public.product_suggestion_counters from anon,authenticated;

create or replace function public.next_product_suggestion_number()
returns text language plpgsql security definer set search_path=public,pg_temp as $$
declare current_year integer:=extract(year from current_date)::integer; next_value bigint;
begin
 insert into public.product_suggestion_counters(year,last_value) values(current_year,1)
 on conflict(year) do update set last_value=public.product_suggestion_counters.last_value+1,updated_at=now()
 returning last_value into next_value;
 return 'IDEA-'||current_year::text||'-'||lpad(next_value::text,6,'0');
end;
$$;

create or replace function public.create_product_suggestion(
 target_company_id uuid,target_title text,target_description text,target_module text default 'roadmap',target_context jsonb default '{}'::jsonb
) returns public.product_suggestions language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.product_suggestions;
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if not public.has_company_permission(target_company_id,'product.suggestions.create') then raise exception 'Permission requise' using errcode='42501'; end if;
 if length(trim(target_title))<4 or length(trim(target_description))<10 then raise exception 'Titre et description obligatoires'; end if;
 insert into public.product_suggestions(suggestion_number,company_id,requester_user_id,title,description,module_key,safe_context)
 values(public.next_product_suggestion_number(),target_company_id,auth.uid(),left(trim(target_title),200),left(trim(target_description),8000),left(trim(target_module),80),public.sanitize_assistant_context(target_context)) returning * into created;
 insert into public.product_suggestion_events(suggestion_id,actor_user_id,event_type,public_summary)
 values(created.id,auth.uid(),'created','Suggestion reçue');
 return created;
end;
$$;

grant execute on function public.next_product_suggestion_number(),
 public.create_product_suggestion(uuid,text,text,text,jsonb) to authenticated;

commit;
