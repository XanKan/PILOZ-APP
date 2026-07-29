begin;

-- A client created from the library, a document or the CRM carries the
-- identity entered for its main contact on public.clients.  Materialise that
-- identity as a real contact so every creation path feeds the Contacts tab.
create or replace function public.create_client_primary_contact_from_identity()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  actor_id uuid:=coalesce(new.created_by,auth.uid());
  new_contact_id uuid;
begin
  if actor_id is null
     or nullif(trim(new.first_name),'') is null
     or nullif(trim(new.last_name),'') is null
     or exists(
       select 1 from public.client_contacts contact
       where contact.client_id=new.id and contact.is_primary
     ) then
    return new;
  end if;

  insert into public.client_contacts(
    company_id,client_id,civility,first_name,last_name,email,phone_e164,
    language,is_primary,active,created_by,updated_by
  ) values (
    new.company_id,new.id,new.civility,trim(new.first_name),trim(new.last_name),
    nullif(lower(trim(new.email)),''),nullif(trim(new.phone_e164),''),
    coalesce(nullif(new.language,''),'fr'),true,true,actor_id,actor_id
  ) returning id into new_contact_id;

  insert into public.client_contact_roles(
    company_id,client_id,contact_id,role,created_by
  ) values(new.company_id,new.id,new_contact_id,'primary',actor_id)
  on conflict(contact_id,role) do nothing;

  insert into public.client_preferences(
    company_id,client_id,default_contact_id,created_by,updated_by
  ) values(new.company_id,new.id,new_contact_id,actor_id,actor_id)
  on conflict(client_id) do update set
    default_contact_id=coalesce(public.client_preferences.default_contact_id,excluded.default_contact_id),
    updated_by=excluded.updated_by,
    updated_at=now();

  return new;
end
$$;

drop trigger if exists clients_create_primary_contact_trigger on public.clients;
create trigger clients_create_primary_contact_trigger
after insert on public.clients
for each row execute function public.create_client_primary_contact_from_identity();

-- Repair existing clients for which the identity was already stored but no
-- contact row was ever created.  Legacy contact_name values are used only
-- when they contain both a first and a last name.
do $$
declare
  source record;
  actor_id uuid;
  new_contact_id uuid;
  first_name_value text;
  last_name_value text;
begin
  for source in
    select client.*
    from public.clients client
    where not exists(
      select 1 from public.client_contacts contact
      where contact.client_id=client.id and contact.is_primary
    )
      and (
        (nullif(trim(client.first_name),'') is not null and nullif(trim(client.last_name),'') is not null)
        or coalesce(client.contact_name,'') ~ '[[:graph:]]+[[:space:]]+[[:graph:]]+'
      )
  loop
    actor_id:=coalesce(
      source.created_by,
      (select member.user_id from public.company_members member
       where member.company_id=source.company_id
       order by member.created_at limit 1)
    );
    if actor_id is null then continue; end if;

    first_name_value:=coalesce(
      nullif(trim(source.first_name),''),
      split_part(trim(source.contact_name),' ',1)
    );
    last_name_value:=coalesce(
      nullif(trim(source.last_name),''),
      nullif(trim(substr(trim(source.contact_name),length(split_part(trim(source.contact_name),' ',1))+1)),'')
    );
    if first_name_value is null or last_name_value is null then continue; end if;

    begin
      insert into public.client_contacts(
        company_id,client_id,civility,first_name,last_name,email,phone_e164,
        language,is_primary,active,created_by,updated_by
      ) values (
        source.company_id,source.id,source.civility,first_name_value,last_name_value,
        nullif(lower(trim(source.email)),''),nullif(trim(source.phone_e164),''),
        coalesce(nullif(source.language,''),'fr'),true,true,actor_id,actor_id
      ) returning id into new_contact_id;

      insert into public.client_contact_roles(
        company_id,client_id,contact_id,role,created_by
      ) values(source.company_id,source.id,new_contact_id,'primary',actor_id)
      on conflict(contact_id,role) do nothing;

      insert into public.client_preferences(
        company_id,client_id,default_contact_id,created_by,updated_by
      ) values(source.company_id,source.id,new_contact_id,actor_id,actor_id)
      on conflict(client_id) do update set
        default_contact_id=coalesce(public.client_preferences.default_contact_id,excluded.default_contact_id),
        updated_by=excluded.updated_by,
        updated_at=now();
    exception when unique_violation then
      null;
    end;
  end loop;
end
$$;

revoke all on function public.create_client_primary_contact_from_identity() from public,anon,authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.60';

commit;
