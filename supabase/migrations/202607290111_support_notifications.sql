begin;

create or replace function public.notify_new_support_ticket()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
  values(
    'support_ticket_created',
    case when new.priority='urgent' then 'critical' when new.priority='high' then 'warning' else 'info' end,
    'Nouveau ticket support',
    new.ticket_number||' · '||left(new.subject,160),
    new.company_id,
    '/support?ticket='||new.id::text
  );
  return new;
end;
$$;

drop trigger if exists support_ticket_created_notification on public.support_tickets;
create trigger support_ticket_created_notification
after insert on public.support_tickets
for each row execute function public.notify_new_support_ticket();

create or replace function public.notify_support_message_participants()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  target public.support_tickets;
begin
  select * into target from public.support_tickets where id=new.ticket_id;
  if target.id is null or new.visibility<>'client' or new.sent_at is null then return new; end if;

  if new.author_kind='support' then
    insert into public.notifications(
      company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by
    ) values(
      target.company_id,target.requester_user_id,'support_reply',
      'Réponse du support Piloz',
      'Une nouvelle réponse est disponible sur le ticket '||target.ticket_number||'.',
      'support_ticket',target.id,'#help/tickets',
      jsonb_build_object('ticket_number',target.ticket_number),
      coalesce(auth.uid(),target.requester_user_id)
    );
  elsif new.author_kind='client' and exists(
    select 1 from public.support_ticket_messages prior
    where prior.ticket_id=new.ticket_id and prior.id<>new.id
  ) then
    insert into public.platform_notifications(event_type,severity,title,message,company_id,action_url)
    values(
      'support_client_message',
      case when target.priority='urgent' then 'critical' when target.priority='high' then 'warning' else 'info' end,
      'Nouveau message client',
      target.ticket_number||' · '||left(target.subject,160),
      target.company_id,
      '/support?ticket='||target.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists support_message_participant_notifications on public.support_ticket_messages;
create trigger support_message_participant_notifications
after insert on public.support_ticket_messages
for each row execute function public.notify_support_message_participants();

create or replace function public.notify_product_suggestion_status()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare target public.product_suggestions;
begin
  if new.public_summary is null then return new; end if;
  select * into target from public.product_suggestions where id=new.suggestion_id;
  if target.id is null or new.actor_admin_id is null then return new; end if;
  insert into public.notifications(
    company_id,user_id,notification_type,title,message,entity_type,entity_id,action_url,metadata,created_by
  ) values(
    target.company_id,target.requester_user_id,'product_suggestion_update',
    'Mise à jour de votre suggestion',
    target.suggestion_number||' · '||new.public_summary,
    'product_suggestion',target.id,'#help/tickets',
    jsonb_build_object('suggestion_number',target.suggestion_number),
    target.requester_user_id
  );
  return new;
end;
$$;

drop trigger if exists product_suggestion_status_notifications on public.product_suggestion_events;
create trigger product_suggestion_status_notifications
after insert on public.product_suggestion_events
for each row execute function public.notify_product_suggestion_status();

revoke all on function public.notify_new_support_ticket(),public.notify_support_message_participants(),public.notify_product_suggestion_status() from public,anon,authenticated;

commit;
