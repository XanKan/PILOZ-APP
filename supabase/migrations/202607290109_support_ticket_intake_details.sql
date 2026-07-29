begin;

alter table public.support_tickets
  add column if not exists request_details jsonb not null default '{}'::jsonb,
  add column if not exists assistant_conversation_id uuid references public.assistant_conversations(id) on delete set null;

create or replace function public.sanitize_support_request_details(input jsonb)
returns jsonb language sql immutable set search_path=public,pg_temp as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'impact', nullif(left(trim(coalesce(input->>'impact','')),1000),''),
    'frequency', case when input->>'frequency' in ('once','intermittent','frequent','always') then input->>'frequency' end,
    'started_on', case when coalesce(input->>'started_on','') ~ '^\d{4}-\d{2}-\d{2}$' then input->>'started_on' end,
    'blocking', case when input->>'blocking' in ('none','partial','total') then input->>'blocking' end,
    'expected_behavior', nullif(left(trim(coalesce(input->>'expected_behavior','')),2000),''),
    'observed_behavior', nullif(left(trim(coalesce(input->>'observed_behavior','')),2000),''),
    'reproduction_steps', nullif(left(trim(coalesce(input->>'reproduction_steps','')),4000),'')
  ));
$$;

drop function if exists public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text);

create function public.create_support_ticket(
 target_company_id uuid,target_subject text,target_description text,target_category text,
 target_module text default null,target_type text default 'support',target_priority text default 'normal',
 target_context jsonb default '{}'::jsonb,target_source text default 'app',
 target_details jsonb default '{}'::jsonb,target_assistant_conversation_id uuid default null
) returns public.support_tickets language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.support_tickets; current_email text;
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if not public.has_company_permission(target_company_id,'support.tickets.create') then raise exception 'Permission support requise' using errcode='42501'; end if;
 if length(trim(target_subject))<4 or length(trim(target_description))<10 then raise exception 'Le sujet et les détails sont obligatoires'; end if;
 if target_category not in ('usage','bug','crm','prospects','pipeline','activities','clients','catalog','quotes','invoices','credit_notes','einvoicing','payments','deadlines','accounting','vat','accounting_exports','purchases','suppliers','users_roles','login','extensions','files','performance','subscription','suggestion','other','roadmap') then raise exception 'Catégorie de support invalide'; end if;
 if target_type not in ('support','incident','request','suggestion') then raise exception 'Type de ticket invalide'; end if;
 if target_priority not in ('low','normal','high','urgent') then raise exception 'Priorité invalide'; end if;
 if target_category='roadmap' then target_type:='suggestion'; target_priority:='normal'; end if;
 if target_priority='urgent' and (
   target_type<>'incident'
   or coalesce(public.sanitize_support_request_details(target_details)->>'blocking','none')<>'total'
 ) then
   target_priority:='high';
 end if;
 if target_assistant_conversation_id is not null and not exists(
   select 1 from public.assistant_conversations conversation
   where conversation.id=target_assistant_conversation_id and conversation.company_id=target_company_id and conversation.user_id=auth.uid()
 ) then raise exception 'Conversation Pilo inaccessible' using errcode='42501'; end if;
 select email into current_email from auth.users where id=auth.uid();
 insert into public.support_tickets(ticket_number,company_id,requester_user_id,requester_email,subject,description,category,module_key,ticket_type,priority,safe_context,source,last_client_message_at,request_details,assistant_conversation_id)
 values(public.next_support_ticket_number(),target_company_id,auth.uid(),current_email,left(trim(target_subject),200),left(trim(target_description),8000),left(trim(target_category),80),left(trim(target_module),80),target_type,target_priority,public.sanitize_assistant_context(target_context),target_source,now(),public.sanitize_support_request_details(target_details),target_assistant_conversation_id) returning * into created;
 insert into public.support_ticket_messages(ticket_id,author_user_id,author_kind,visibility,body,sent_at)
 values(created.id,auth.uid(),'client','client',created.description,now());
 insert into public.support_ticket_events(ticket_id,company_id,actor_user_id,event_type,public_summary)
 values(created.id,target_company_id,auth.uid(),'created','Ticket créé');
 return created;
end;
$$;

drop view if exists public.support_ticket_client_view;
create view public.support_ticket_client_view with (security_invoker=true) as
select id,ticket_number,company_id,requester_user_id,subject,category,module_key,ticket_type,priority,status,safe_context,source,
 request_details,assistant_conversation_id,first_response_at,resolved_at,closed_at,last_client_message_at,last_support_message_at,created_at,updated_at
from public.support_tickets;

grant execute on function public.sanitize_support_request_details(jsonb),public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid) to authenticated;
grant select(id,ticket_number,company_id,requester_user_id,subject,category,module_key,ticket_type,priority,status,safe_context,source,request_details,assistant_conversation_id,first_response_at,resolved_at,closed_at,last_client_message_at,last_support_message_at,created_at,updated_at) on public.support_tickets to authenticated;
grant select on public.support_ticket_client_view to authenticated;

commit;
