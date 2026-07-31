begin;

create or replace function public.create_support_ticket(
 target_company_id uuid,target_subject text,target_description text,target_category text,
 target_module text default null,target_type text default 'support',target_priority text default 'normal',
 target_context jsonb default '{}'::jsonb,target_source text default 'app',
 target_details jsonb default '{}'::jsonb,target_assistant_conversation_id uuid default null
) returns public.support_tickets language plpgsql security definer set search_path=public,pg_temp as $$
declare created public.support_tickets; current_email text;
begin
 if auth.uid() is null or not public.is_company_member(target_company_id) then raise exception 'Accès refusé' using errcode='42501'; end if;
 if not public.has_company_permission(target_company_id,'support.tickets.create') then raise exception 'Permission support requise' using errcode='42501'; end if;
 if length(trim(target_subject))<4 or length(trim(target_description))<4 then raise exception 'Le titre et la description doivent contenir au moins 4 caractères'; end if;
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

grant execute on function public.create_support_ticket(uuid,text,text,text,text,text,text,jsonb,text,jsonb,uuid) to authenticated;

commit;
