begin;

-- Les anciens booléens de permissions sont des compatibilités, pas des moyens
-- de restreindre le rôle Administrateur système. Ce rôle doit toujours rester
-- la source d'autorité complète de l'entreprise.
create or replace function public.company_permission_scope(
  target_company_id uuid,target_permission text,target_user_id uuid default auth.uid()
) returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare member_row public.company_members%rowtype; role_row public.company_roles%rowtype; canonical text; resolved_scope text;
begin
  select * into member_row from public.company_members member
  where member.company_id=target_company_id and member.user_id=target_user_id and member.platform_status='active';
  if member_row.user_id is null then return 'none'; end if;
  select * into role_row from public.company_roles role where role.id=member_row.role_id and role.company_id=target_company_id and role.active;
  if role_row.system_key='administrator' then return 'company'; end if;
  select definition.canonical_key into canonical from public.permission_definitions definition
  where definition.permission_key=target_permission and definition.active;
  canonical:=coalesce(canonical,target_permission);
  if member_row.permissions ? target_permission then
    if lower(member_row.permissions->>target_permission)='false' then return 'none'; end if;
    if lower(member_row.permissions->>target_permission)='true' then return 'company'; end if;
  end if;
  if member_row.permissions ? canonical then
    if lower(member_row.permissions->>canonical)='false' then return 'none'; end if;
    if lower(member_row.permissions->>canonical)='true' then return 'company'; end if;
  end if;
  select permission.scope into resolved_scope from public.company_role_permissions permission
  join public.company_roles role on role.id=permission.role_id and role.company_id=target_company_id and role.active
  where permission.role_id=member_row.role_id and permission.permission_key=canonical;
  if resolved_scope is not null then return resolved_scope; end if;
  if member_row.role in('owner','admin') then return 'company'; end if;
  return 'none';
end
$$;
revoke all on function public.company_permission_scope(uuid,text,uuid) from public,anon;
grant execute on function public.company_permission_scope(uuid,text,uuid) to authenticated;

-- Le rôle reste une barrière dure : un ancien alias de permission ne doit
-- jamais transformer un auditeur ou un lecteur en utilisateur modificateur.
create or replace function public._crm_context()
returns table(company_id uuid,role text,can_manage boolean,can_view_all boolean,can_write boolean,can_margin boolean)
language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id,member.role,
    member.role in('owner','admin') and (
      public.has_company_permission(member.company_id,'company.settings.manage')
      or public.has_company_permission(member.company_id,'manage_customer')
    ),
    member.role in('owner','admin'),
    member.role not in('auditor','read_only') and (
      public.has_company_permission(member.company_id,'crm.opportunities.write')
      or public.has_company_permission(member.company_id,'crm.prospects.write')
      or public.has_company_permission(member.company_id,'crm.activities.write')
      or public.has_company_permission(member.company_id,'manage_customer')
      or public.has_company_permission(member.company_id,'manage_opportunity')
      or public.has_company_permission(member.company_id,'manage_reminder')
    ),
    public.has_company_permission(member.company_id,'view_margins')
      or public.has_company_permission(member.company_id,'sales.margins.read')
  from public.company_members member
  left join public.user_preferences preference on preference.user_id=member.user_id
  where member.user_id=auth.uid() and member.platform_status='active'
    and (preference.company_id is null or preference.company_id=member.company_id)
  order by case when preference.company_id=member.company_id then 0 else 1 end,member.created_at
  limit 1
$$;

-- Les permissions sensibles du CRM sont distinctes : consulter les rapports ne
-- donne jamais automatiquement accès aux montants ou aux performances d'équipe.
insert into public.permission_definitions(permission_key,canonical_key,module_key,category_key,category_label,label,description,allowed_scopes,sensitive,editor_visible,position) values
('crm.reports.export','crm.reports.export','crm','crm','Suivi commercial','Exporter les rapports commerciaux','Exporter uniquement les données commerciales visibles dans la portée autorisée.',array['own','team','company'],true,true,128),
('crm.amounts.read','crm.amounts.read','crm','crm','Suivi commercial','Consulter les montants commerciaux','Afficher les montants, valeurs pondérées et prévisions du périmètre autorisé.',array['own','team','company'],true,true,129),
('crm.performance.read','crm.performance.read','crm','crm','Suivi commercial','Consulter les performances commerciales','Afficher les indicateurs de performance individuels autorisés.',array['own','team','company'],true,true,130),
('crm.team_activities.read','crm.team_activities.read','crm','crm','Suivi commercial','Consulter les activités de l’équipe','Afficher les agendas et activités des collaborateurs autorisés.',array['team','company'],true,true,131)
on conflict(permission_key) do update set canonical_key=excluded.canonical_key,module_key=excluded.module_key,
  category_key=excluded.category_key,category_label=excluded.category_label,label=excluded.label,
  description=excluded.description,allowed_scopes=excluded.allowed_scopes,sensitive=excluded.sensitive,
  editor_visible=excluded.editor_visible,position=excluded.position,active=true;

insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,'company'
from public.company_roles role
cross join (values('crm.reports.export'),('crm.amounts.read'),('crm.performance.read'),('crm.team_activities.read')) permission(permission_key)
where role.active and role.system_key='administrator'
on conflict(role_id,permission_key) do update set scope=excluded.scope,updated_at=now();

insert into public.company_role_permissions(role_id,permission_key,scope)
select role.id,permission.permission_key,permission.scope
from public.company_roles role
cross join (values('crm.amounts.read','team'),('crm.performance.read','own'),('crm.team_activities.read','team')) permission(permission_key,scope)
where role.active and role.system_key='commercial'
on conflict(role_id,permission_key) do nothing;

create or replace function public._crm_has_scope(
  target_company_id uuid,target_permission text,target_owner_id uuid,target_team_id uuid
) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.has_company_permission(target_company_id,target_permission,'own',target_owner_id,target_team_id)
$$;
revoke all on function public._crm_has_scope(uuid,text,uuid,uuid) from public,anon;
grant execute on function public._crm_has_scope(uuid,text,uuid,uuid) to authenticated;

-- Les politiques historiques vérifiaient des alias trop larges. Elles sont
-- réalignées sur le contexte CRM central afin que le rôle lecture seule reste
-- effectivement non modificateur, y compris en accès REST direct.
do $crm_rework_business_rls$
declare table_name text;
begin
  foreach table_name in array array[
    'crm_opportunity_products','crm_activity_participants','crm_activity_links',
    'crm_notes','crm_tag_assignments','crm_custom_field_values','crm_sequence_enrollments'
  ] loop
    execute format('drop policy if exists %I on public.%I',table_name||'_insert',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_update',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_delete',table_name);
    execute format(
      'create policy %I on public.%I for insert to authenticated with check(created_by=auth.uid() and exists(select 1 from public._crm_context() context where context.company_id=%I.company_id and context.can_write))',
      table_name||'_insert',table_name,table_name
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using(exists(select 1 from public._crm_context() context where context.company_id=%I.company_id and context.can_write)) with check(exists(select 1 from public._crm_context() context where context.company_id=%I.company_id and context.can_write))',
      table_name||'_update',table_name,table_name,table_name
    );
    execute format(
      'create policy %I on public.%I for delete to authenticated using(exists(select 1 from public._crm_context() context where context.company_id=%I.company_id and context.can_write))',
      table_name||'_delete',table_name,table_name
    );
  end loop;
end
$crm_rework_business_rls$;

-- Refonte CRM additive : le montant saisi reste conservé, tandis que le montant
-- affiché devient canonique et provient d'un devis actif dès qu'il existe.
alter table public.opportunities
  add column if not exists estimated_amount numeric(15,2),
  add column if not exists documentary_amount numeric(15,2) not null default 0,
  add column if not exists amount_source text not null default 'estimated',
  add column if not exists origin_prospect_id uuid references public.clients(id) on delete set null,
  add column if not exists tags text[] not null default '{}';

update public.opportunities
set estimated_amount=coalesce(estimated_amount,amount,0),
    amount_source=case when amount_source in('estimated','documentary') then amount_source else 'estimated' end
where estimated_amount is null or amount_source not in('estimated','documentary');

alter table public.opportunities drop constraint if exists opportunities_amount_source_check;
alter table public.opportunities add constraint opportunities_amount_source_check
  check(amount_source in('estimated','documentary')) not valid;

alter table public.documents
  add column if not exists crm_relation_type text,
  add column if not exists crm_replaced_by_id uuid references public.documents(id) on delete set null;
alter table public.documents drop constraint if exists documents_crm_relation_type_check;
alter table public.documents add constraint documents_crm_relation_type_check
  check(crm_relation_type is null or crm_relation_type in('primary','variant','complement','replaced')) not valid;

create index if not exists documents_crm_opportunity_amount_idx
  on public.documents(company_id,opportunity_id,document_type,crm_relation_type,status,updated_at desc)
  where opportunity_id is not null;
create index if not exists opportunities_crm_amount_idx
  on public.opportunities(company_id,amount_source,amount desc)
  where archived_at is null;

-- Un seul devis historique devient principal. Les autres restent consultables
-- comme variantes ou devis remplacés : aucune relation n'est supprimée.
with ranked as(
  select document.id,document.status,
    row_number() over(
      partition by document.company_id,document.opportunity_id
      order by case when document.archived_at is null and coalesce(document.status,'') not in('cancelled','archived','rejected','refused','expired') then 0 else 1 end,
               coalesce(document.validated_at,document.updated_at,document.created_at) desc,document.id desc
    ) rank_value
  from public.documents document
  where document.document_type='quote' and document.opportunity_id is not null and document.crm_relation_type is null
)
update public.documents document
set crm_relation_type=case
  when ranked.rank_value=1 and coalesce(ranked.status,'') not in('cancelled','archived','rejected','refused','expired') then 'primary'
  when coalesce(ranked.status,'') in('cancelled','archived','rejected','refused','expired') then 'replaced'
  else 'variant' end
from ranked where ranked.id=document.id;

create or replace function public._recalculate_crm_opportunity_amount(target_opportunity_id uuid,target_company_id uuid)
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare opportunity_row public.opportunities%rowtype;document_total numeric(15,2):=0;document_count integer:=0;include_drafts boolean:=false;
begin
  select opportunity.* into opportunity_row from public.opportunities opportunity
  where opportunity.id=target_opportunity_id and opportunity.company_id=target_company_id for update;
  if opportunity_row.id is null then return null; end if;

  select coalesce((pipeline.automation_settings->>'include_draft_quotes')::boolean,false)
  into include_drafts from public.crm_pipelines pipeline where pipeline.id=opportunity_row.pipeline_id;

  select count(*),coalesce(round(sum(coalesce(document.total_excl_tax,0)),2),0)
  into document_count,document_total
  from public.documents document
  where document.company_id=target_company_id
    and document.opportunity_id=target_opportunity_id
    and document.document_type='quote'
    and document.archived_at is null
    and coalesce(document.status,'') not in('cancelled','archived','rejected','refused','expired')
    and (include_drafts or coalesce(document.status,'draft')<>'draft')
    and coalesce(document.crm_relation_type,'primary') in('primary','complement')
    and document.crm_replaced_by_id is null;

  update public.opportunities opportunity set
    estimated_amount=coalesce(opportunity.estimated_amount,opportunity.amount,0),
    documentary_amount=document_total,
    amount=case when document_count>0 then document_total else coalesce(opportunity.estimated_amount,opportunity.amount,0) end,
    amount_source=case when document_count>0 then 'documentary' else 'estimated' end,
    updated_at=now()
  where opportunity.id=target_opportunity_id and opportunity.company_id=target_company_id
  returning opportunity.* into opportunity_row;
  return opportunity_row;
end
$$;

create or replace function public.recalculate_crm_opportunity_amount(target_opportunity_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into opportunity_row from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id;
  if opportunity_row.id is null then raise exception 'crm_opportunity_not_found' using errcode='P0002'; end if;
  if not public._crm_has_scope(opportunity_row.company_id,'crm.opportunities.write',coalesce(opportunity_row.assigned_user_id,opportunity_row.owner_user_id,opportunity_row.created_by),opportunity_row.team_id) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  opportunity_row:=public._recalculate_crm_opportunity_amount(target_opportunity_id,context_row.company_id);
  return jsonb_build_object('id',opportunity_row.id,'estimated_amount',opportunity_row.estimated_amount,
    'documentary_amount',opportunity_row.documentary_amount,'amount',opportunity_row.amount,'amount_source',opportunity_row.amount_source);
end
$$;

create or replace function public.sync_crm_opportunity_document_amount()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op<>'INSERT' and old.opportunity_id is not null then
    perform public._recalculate_crm_opportunity_amount(old.opportunity_id,old.company_id);
  end if;
  if tg_op<>'DELETE' and new.opportunity_id is not null
    and (tg_op='INSERT' or new.opportunity_id is distinct from old.opportunity_id or new.company_id is distinct from old.company_id) then
    perform public._recalculate_crm_opportunity_amount(new.opportunity_id,new.company_id);
  elsif tg_op='UPDATE' and new.opportunity_id is not null then
    perform public._recalculate_crm_opportunity_amount(new.opportunity_id,new.company_id);
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists documents_sync_crm_amount on public.documents;
create trigger documents_sync_crm_amount
after insert or delete or update of opportunity_id,total_excl_tax,status,archived_at,crm_relation_type,crm_replaced_by_id
on public.documents for each row execute function public.sync_crm_opportunity_document_amount();

-- Pipeline cible. Les anciennes étapes restent présentes mais inactives lorsque
-- leur sens ne correspond plus au parcours commercial demandé.
create or replace function public._crm_apply_sales_stage_rework(target_company_id uuid,target_owner_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare pipeline_uuid uuid;source_stage uuid;target_stage uuid;stage_row record;target_slug text;
begin
  select id into pipeline_uuid from public.crm_pipelines
  where company_id=target_company_id and is_default and status<>'archived' order by position,id limit 1;
  if pipeline_uuid is null then
    perform public._crm_seed_company(target_company_id,target_owner_id);
    select id into pipeline_uuid from public.crm_pipelines
    where company_id=target_company_id and is_default and status<>'archived' order by position,id limit 1;
  end if;
  if pipeline_uuid is null then return; end if;

  -- L'ancien « Besoin identifié » portait le slug qualified.
  select id into source_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='qualified' limit 1;
  if source_stage is not null and not exists(select 1 from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='need_identified') then
    update public.pipeline_stages set slug='need_identified',name='Besoin identifié',position=50,probability=55,color='#8b5cf6',updated_by=target_owner_id,updated_at=now() where id=source_stage;
    update public.opportunities set stage='need_identified' where company_id=target_company_id and pipeline_stage_id=source_stage;
  end if;

  select id into source_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='contacted' limit 1;
  select id into target_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='qualified' limit 1;
  if source_stage is not null and target_stage is null then
    update public.pipeline_stages set slug='qualified',name='Qualifié',position=30,probability=30,color='#0ea5e9',updated_by=target_owner_id,updated_at=now() where id=source_stage;
    update public.opportunities set stage='qualified' where company_id=target_company_id and pipeline_stage_id=source_stage;
  elsif source_stage is not null and target_stage is not null and source_stage<>target_stage then
    update public.opportunities set pipeline_stage_id=target_stage,stage='qualified' where company_id=target_company_id and pipeline_stage_id=source_stage;
    update public.pipeline_stages set active=false,stage_type='suspended',name='Contact établi (historique)',updated_by=target_owner_id,updated_at=now() where id=source_stage;
  end if;

  select id into source_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='proposal' limit 1;
  if source_stage is not null and not exists(select 1 from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='quote_preparation') then
    update public.pipeline_stages set slug='quote_preparation',name='Devis à préparer',position=60,probability=65,color='#a855f7',updated_by=target_owner_id,updated_at=now() where id=source_stage;
    update public.opportunities set stage='quote_preparation' where company_id=target_company_id and pipeline_stage_id=source_stage;
  end if;

  insert into public.pipeline_stages(company_id,pipeline_id,name,slug,position,probability,color,active,is_won,is_lost,stage_type,recommended_delay_days,created_by,updated_by)
  select target_company_id,pipeline_uuid,value.name,value.slug,value.position,value.probability,value.color,true,value.kind='won',value.kind='lost',value.kind,value.delay,target_owner_id,target_owner_id
  from(values
    ('Nouveau','new',10,5::numeric,'#64748b','open',2),('À qualifier','to_qualify',20,15::numeric,'#3b82f6','open',4),
    ('Qualifié','qualified',30,30::numeric,'#0ea5e9','open',7),('Rendez-vous planifié','meeting',40,40::numeric,'#6366f1','open',10),
    ('Besoin identifié','need_identified',50,55::numeric,'#8b5cf6','open',10),('Devis à préparer','quote_preparation',60,65::numeric,'#a855f7','open',7),
    ('Devis envoyé','quote_sent',70,75::numeric,'#f59e0b','open',10),('Gagné','won',80,100::numeric,'#16a34a','won',null),
    ('Perdu','lost',90,0::numeric,'#ef4444','lost',null)
  )value(name,slug,position,probability,color,kind,delay)
  where not exists(select 1 from public.pipeline_stages stage where stage.company_id=target_company_id and stage.pipeline_id=pipeline_uuid and stage.slug=value.slug);

  update public.pipeline_stages stage set name=value.name,position=value.position,probability=value.probability,color=value.color,
    active=true,is_won=value.kind='won',is_lost=value.kind='lost',stage_type=value.kind,updated_by=target_owner_id,updated_at=now()
  from(values
    ('Nouveau','new',10,5::numeric,'#64748b','open'),('À qualifier','to_qualify',20,15::numeric,'#3b82f6','open'),
    ('Qualifié','qualified',30,30::numeric,'#0ea5e9','open'),('Rendez-vous planifié','meeting',40,40::numeric,'#6366f1','open'),
    ('Besoin identifié','need_identified',50,55::numeric,'#8b5cf6','open'),('Devis à préparer','quote_preparation',60,65::numeric,'#a855f7','open'),
    ('Devis envoyé','quote_sent',70,75::numeric,'#f59e0b','open'),('Gagné','won',80,100::numeric,'#16a34a','won'),
    ('Perdu','lost',90,0::numeric,'#ef4444','lost')
  )value(name,slug,position,probability,color,kind)
  where stage.company_id=target_company_id and stage.pipeline_id=pipeline_uuid and stage.slug=value.slug;

  select id into source_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='negotiation' limit 1;
  select id into target_stage from public.pipeline_stages where company_id=target_company_id and pipeline_id=pipeline_uuid and slug='quote_sent' limit 1;
  if source_stage is not null then
    update public.opportunities set pipeline_stage_id=target_stage,stage='quote_sent',stage_entered_at=now(),updated_at=now()
    where company_id=target_company_id and pipeline_stage_id=source_stage;
    update public.pipeline_stages set active=false,stage_type='suspended',name='Négociation (historique)',updated_by=target_owner_id,updated_at=now() where id=source_stage;
  end if;

  -- Toute ancienne étape encore active est conservée comme historique. Ses
  -- opportunités sont rattachées à l'étape cible la plus proche, selon son
  -- résultat et sa probabilité, afin de ne jamais perdre ni masquer un dossier.
  for stage_row in
    select * from public.pipeline_stages stage
    where stage.company_id=target_company_id and stage.pipeline_id=pipeline_uuid and stage.active
      and stage.slug not in('new','to_qualify','qualified','meeting','need_identified','quote_preparation','quote_sent','won','lost')
  loop
    target_slug:=case
      when stage_row.is_won or stage_row.stage_type='won' then 'won'
      when stage_row.is_lost or stage_row.stage_type='lost' then 'lost'
      when coalesce(stage_row.probability,0)<10 then 'new'
      when coalesce(stage_row.probability,0)<25 then 'to_qualify'
      when coalesce(stage_row.probability,0)<35 then 'qualified'
      when coalesce(stage_row.probability,0)<50 then 'meeting'
      when coalesce(stage_row.probability,0)<60 then 'need_identified'
      when coalesce(stage_row.probability,0)<70 then 'quote_preparation'
      else 'quote_sent' end;
    select id into target_stage from public.pipeline_stages
    where company_id=target_company_id and pipeline_id=pipeline_uuid and slug=target_slug limit 1;
    update public.opportunities set pipeline_stage_id=target_stage,stage=target_slug,stage_entered_at=now(),updated_at=now()
    where company_id=target_company_id and pipeline_stage_id=stage_row.id;
    update public.pipeline_stages set active=false,is_won=false,is_lost=false,stage_type='suspended',
      name=case when name like '%(historique)' then name else name||' (historique)' end,
      updated_by=target_owner_id,updated_at=now() where id=stage_row.id;
  end loop;
end
$$;

create or replace function public.seed_company_crm_rework()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public._crm_apply_sales_stage_rework(new.id,new.owner_user_id);return new;end
$$;
drop trigger if exists companies_seed_crm_rework on public.companies;
create trigger companies_seed_crm_rework after insert on public.companies for each row execute function public.seed_company_crm_rework();

do $stage_migration$
declare company_row record;
begin
  for company_row in select id,owner_user_id from public.companies loop
    perform public._crm_apply_sales_stage_rework(company_row.id,company_row.owner_user_id);
  end loop;
end
$stage_migration$;

update public.opportunities set priority='normal' where priority in('medium','average') or priority is null;
update public.opportunities set priority='urgent' where priority in('critical','critique');
update public.activities set priority='normal' where priority in('medium','average') or priority is null;
update public.activities set priority='urgent' where priority in('critical','critique');

alter table public.activities drop constraint if exists activities_activity_type_check;
alter table public.activities add constraint activities_activity_type_check check(activity_type in(
  'call','email','meeting','video','task','note','reminder','demo','visit','event','quote_followup','other'
)) not valid;

-- Sélecteur premium client/prospect : 6 récents à vide, recherche multi-champs
-- et contacts renvoyés sans exposer les tiers d'une autre entreprise.
create or replace function public.get_crm_party_picker(target_search text default null,target_limit integer default 6,target_relationship text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;needle text:=lower(trim(coalesce(target_search,'')));limit_value integer:=least(25,greatest(1,coalesce(target_limit,6)));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then raise exception 'crm_access_denied' using errcode='42501'; end if;
  return jsonb_build_object('rows',coalesce((
    select jsonb_agg(to_jsonb(result) order by result.search_rank,result.updated_at desc)
    from(
      select client.id,client.relationship_type,client.kind,client.legal_name,client.trade_name,client.first_name,client.last_name,
        client.email,client.phone_e164,client.siren,client.siret,client.assigned_user_id,client.updated_at,
        case when needle='' then 1 when lower(coalesce(client.legal_name,client.trade_name,client.first_name||' '||client.last_name,''))=needle then 0 else 1 end search_rank,
        coalesce((select jsonb_agg(jsonb_build_object('id',contact.id,'first_name',contact.first_name,'last_name',contact.last_name,'job_title',contact.job_title,'email',contact.email,'phone',contact.phone_e164,'is_primary',contact.is_primary) order by contact.is_primary desc,contact.last_name,contact.first_name)
          from public.client_contacts contact where contact.company_id=client.company_id and contact.client_id=client.id),'[]'::jsonb) contacts
      from public.clients client
      where client.company_id=context_row.company_id and client.active and client.relationship_type in('client','prospect')
        and (target_relationship is null or target_relationship='' or client.relationship_type=target_relationship)
        and public._crm_has_scope(client.company_id,
          case when client.relationship_type='prospect' then 'crm.prospects.read' else 'clients.read' end,
          coalesce(client.assigned_user_id,client.created_by),client.team_id)
        and (needle='' or lower(coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(client.first_name,'')||' '||coalesce(client.last_name,'')||' '||coalesce(client.email,'')||' '||coalesce(client.phone_e164,'')||' '||coalesce(client.siren,'')||' '||coalesce(client.siret,'')) like '%'||needle||'%')
      order by search_rank,client.updated_at desc limit limit_value
    )result
  ),'[]'::jsonb),'query',needle,'limit',limit_value);
end
$$;

create or replace function public.create_crm_party(target_payload jsonb)
returns public.clients language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.clients%rowtype;relationship_value text;kind_value text;display_name text;email_value text;
  assigned_value uuid;team_value uuid;permission_key text;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then raise exception 'crm_forbidden' using errcode='42501'; end if;
  relationship_value:=coalesce(nullif(target_payload->>'relationship_type',''),'prospect');
  kind_value:=coalesce(nullif(target_payload->>'kind',''),'company');
  if relationship_value not in('client','prospect') or kind_value not in('company','person') then raise exception 'crm_invalid_party'; end if;
  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,auth.uid());
  team_value:=nullif(target_payload->>'team_id','')::uuid;
  permission_key:=case when relationship_value='prospect' then 'crm.prospects.write' else 'clients.write' end;
  if not public._crm_has_scope(context_row.company_id,permission_key,assigned_value,team_value) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  display_name:=trim(coalesce(nullif(target_payload->>'legal_name',''),nullif(target_payload->>'trade_name',''),nullif(concat_ws(' ',target_payload->>'first_name',target_payload->>'last_name'),''),''));
  if display_name='' then raise exception 'crm_party_name_required'; end if;
  email_value:=nullif(lower(trim(target_payload->>'email')),'');
  if email_value is not null and exists(select 1 from public.clients where company_id=context_row.company_id and lower(email)=email_value and active) then raise exception 'crm_duplicate_email'; end if;
  insert into public.clients(company_id,kind,legal_name,trade_name,first_name,last_name,email,phone_e164,siren,siret,country_code,relationship_type,crm_status,assigned_user_id,team_id,contact_name,created_by)
  values(context_row.company_id,kind_value,display_name,nullif(trim(target_payload->>'trade_name'),''),nullif(trim(target_payload->>'first_name'),''),nullif(trim(target_payload->>'last_name'),''),
    email_value,nullif(trim(target_payload->>'phone_e164'),''),nullif(trim(target_payload->>'siren'),''),nullif(trim(target_payload->>'siret'),''),coalesce(nullif(upper(trim(target_payload->>'country_code')),''),'FR'),
    relationship_value,case when relationship_value='prospect' then 'new' else 'converted' end,assigned_value,team_value,nullif(trim(target_payload->>'contact_name'),''),auth.uid()) returning * into result;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,created_by)
  values(result.company_id,result.relationship_type,result.id,result.relationship_type||'_created',case when result.relationship_type='client' then 'Client créé' else 'Prospect créé' end,display_name,auth.uid());
  return result;
end
$$;

create or replace function public.save_crm_opportunity_v2(target_opportunity_id uuid,target_payload jsonb)
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.opportunities%rowtype;existing public.opportunities%rowtype;party public.clients%rowtype;contact public.client_contacts%rowtype;
  pipeline_row public.crm_pipelines%rowtype;stage_row public.pipeline_stages%rowtype;priority_value text;estimated_value numeric(15,2);
  collaborators uuid[]:='{}';assigned_value uuid;team_value uuid;previous_stage uuid;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null then raise exception 'crm_forbidden' using errcode='42501'; end if;
  select * into party from public.clients where id=nullif(target_payload->>'client_id','')::uuid and company_id=context_row.company_id and active and relationship_type in('client','prospect');
  if party.id is null then raise exception 'crm_party_required'; end if;
  if nullif(target_payload->>'contact_id','') is not null then
    select * into contact from public.client_contacts where id=(target_payload->>'contact_id')::uuid and company_id=context_row.company_id and client_id=party.id;
    if contact.id is null then raise exception 'crm_contact_invalid'; end if;
  end if;
  priority_value:=coalesce(nullif(target_payload->>'priority',''),'normal');
  if priority_value not in('low','normal','high','urgent') then raise exception 'crm_priority_invalid'; end if;
  estimated_value:=greatest(0,coalesce(nullif(target_payload->>'estimated_amount','')::numeric,nullif(target_payload->>'amount','')::numeric,0));
  if jsonb_typeof(target_payload->'collaborator_user_ids')='array' then
    select coalesce(array_agg(member.user_id),'{}'::uuid[]) into collaborators
    from jsonb_array_elements_text(target_payload->'collaborator_user_ids') value
    join public.company_members member on member.user_id=value::uuid and member.company_id=context_row.company_id and member.platform_status='active';
  end if;
  if target_opportunity_id is not null then
    select * into existing from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
    if existing.id is null or not public._crm_has_scope(existing.company_id,'crm.opportunities.write',coalesce(existing.assigned_user_id,existing.owner_user_id,existing.created_by),existing.team_id) then
      raise exception 'crm_forbidden' using errcode='42501';
    end if;
  end if;
  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,existing.assigned_user_id,auth.uid());
  team_value:=coalesce(nullif(target_payload->>'team_id','')::uuid,existing.team_id);
  if not public._crm_has_scope(context_row.company_id,'crm.opportunities.write',assigned_value,team_value) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  if not public._crm_has_scope(party.company_id,case when party.relationship_type='prospect' then 'crm.prospects.read' else 'clients.read' end,coalesce(party.assigned_user_id,party.created_by),party.team_id) then
    raise exception 'crm_party_forbidden' using errcode='42501';
  end if;
  select * into pipeline_row from public.crm_pipelines where company_id=context_row.company_id and status='active'
    and id=coalesce(nullif(target_payload->>'pipeline_id','')::uuid,existing.pipeline_id,(select id from public.crm_pipelines where company_id=context_row.company_id and is_default and status='active' limit 1));
  select * into stage_row from public.pipeline_stages where company_id=context_row.company_id and pipeline_id=pipeline_row.id and active
    and id=coalesce(nullif(target_payload->>'stage_id','')::uuid,existing.pipeline_stage_id,(select id from public.pipeline_stages where pipeline_id=pipeline_row.id and active order by position limit 1));
  if pipeline_row.id is null or stage_row.id is null or nullif(trim(target_payload->>'name'),'') is null or stage_row.stage_type in('won','lost') then raise exception 'crm_invalid_opportunity'; end if;
  if target_opportunity_id is null then
    insert into public.opportunities(company_id,client_id,name,stage,amount,estimated_amount,probability,owner_user_id,next_action_at,notes,contact_id,
      expected_close_date,assigned_user_id,team_id,source,need_subject,description,priority,health,collaborator_user_ids,pipeline_id,pipeline_stage_id,
      source_id,primary_contact_id,forecast_category,opportunity_type,recurring_amount,recurrence,next_action,origin_prospect_id,tags,created_by,updated_by)
    values(context_row.company_id,party.id,trim(target_payload->>'name'),stage_row.slug,estimated_value,estimated_value,
      least(100,greatest(0,coalesce(nullif(target_payload->>'probability','')::numeric,stage_row.probability))),assigned_value,
      nullif(target_payload->>'next_action_at','')::timestamptz,nullif(target_payload->>'notes',''),contact.id,
      nullif(target_payload->>'expected_close_date','')::date,assigned_value,team_value,nullif(target_payload->>'source',''),nullif(target_payload->>'need_subject',''),
      nullif(target_payload->>'description',''),priority_value,'watch',collaborators,pipeline_row.id,stage_row.id,nullif(target_payload->>'source_id','')::uuid,
      contact.id,coalesce(nullif(target_payload->>'forecast_category',''),'potential'),nullif(target_payload->>'opportunity_type',''),
      nullif(target_payload->>'recurring_amount','')::numeric,nullif(target_payload->>'recurrence',''),nullif(target_payload->>'next_action',''),
      case when party.relationship_type='prospect' then party.id end,
      coalesce((select array_agg(trim(value)) from jsonb_array_elements_text(coalesce(target_payload->'tags','[]'::jsonb)) value where trim(value)<>''),'{}'::text[]),auth.uid(),auth.uid()) returning * into result;
  else
    previous_stage:=existing.pipeline_stage_id;
    update public.opportunities set client_id=party.id,name=trim(target_payload->>'name'),stage=stage_row.slug,amount=estimated_value,estimated_amount=estimated_value,
      probability=least(100,greatest(0,coalesce(nullif(target_payload->>'probability','')::numeric,stage_row.probability))),owner_user_id=assigned_value,
      next_action_at=nullif(target_payload->>'next_action_at','')::timestamptz,notes=nullif(target_payload->>'notes',''),contact_id=contact.id,
      expected_close_date=nullif(target_payload->>'expected_close_date','')::date,assigned_user_id=assigned_value,team_id=team_value,
      source=nullif(target_payload->>'source',''),need_subject=nullif(target_payload->>'need_subject',''),description=nullif(target_payload->>'description',''),
      priority=priority_value,collaborator_user_ids=collaborators,pipeline_id=pipeline_row.id,pipeline_stage_id=stage_row.id,source_id=nullif(target_payload->>'source_id','')::uuid,
      primary_contact_id=contact.id,forecast_category=coalesce(nullif(target_payload->>'forecast_category',''),forecast_category),
      opportunity_type=nullif(target_payload->>'opportunity_type',''),recurring_amount=nullif(target_payload->>'recurring_amount','')::numeric,
      recurrence=nullif(target_payload->>'recurrence',''),next_action=nullif(target_payload->>'next_action',''),
      origin_prospect_id=case when party.relationship_type='prospect' then coalesce(origin_prospect_id,party.id) else origin_prospect_id end,
      tags=coalesce((select array_agg(trim(value)) from jsonb_array_elements_text(coalesce(target_payload->'tags','[]'::jsonb)) value where trim(value)<>''),'{}'::text[]),
      stage_entered_at=case when previous_stage is distinct from stage_row.id then now() else stage_entered_at end,updated_by=auth.uid(),updated_at=now()
    where id=existing.id returning * into result;
  end if;
  result:=public._recalculate_crm_opportunity_amount(result.id,result.company_id);
  return result;
end
$$;

create or replace function public.move_crm_opportunity(target_opportunity_id uuid,target_stage_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;stage_row public.pipeline_stages%rowtype;previous_stage uuid;
begin
  select * into context_row from public._crm_context();
  select * into opportunity_row from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
  select * into stage_row from public.pipeline_stages where id=target_stage_id and company_id=context_row.company_id and pipeline_id=opportunity_row.pipeline_id and active;
  if opportunity_row.id is null or stage_row.id is null
    or not public._crm_has_scope(opportunity_row.company_id,'crm.opportunities.write',coalesce(opportunity_row.assigned_user_id,opportunity_row.owner_user_id,opportunity_row.created_by),opportunity_row.team_id) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  if stage_row.stage_type in('won','lost') then raise exception 'crm_close_dialog_required'; end if;
  previous_stage:=opportunity_row.pipeline_stage_id;
  update public.opportunities set pipeline_stage_id=stage_row.id,stage=stage_row.slug,probability=stage_row.probability,
    stage_entered_at=now(),forecast_category=case when forecast_category in('won','lost') then 'potential' else forecast_category end,
    health=case when health in('won','lost') then 'watch' else health end,closed_at=null,updated_by=auth.uid(),updated_at=now()
  where id=opportunity_row.id;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
  values(opportunity_row.company_id,'opportunity',opportunity_row.id,'stage_changed','Étape modifiée',stage_row.name,
    jsonb_build_object('from_stage_id',previous_stage,'to_stage_id',stage_row.id),auth.uid());
  return jsonb_build_object('id',opportunity_row.id,'stage_id',stage_row.id,'stage',stage_row.slug,'probability',stage_row.probability,'updated_at',now());
end
$$;

create or replace function public.close_crm_opportunity(target_opportunity_id uuid,target_outcome text,target_amount numeric default null,target_reason_id uuid default null,target_comment text default null,target_closed_at timestamptz default now())
returns public.opportunities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;stage_row public.pipeline_stages%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into opportunity_row from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id for update;
  if opportunity_row.id is null or target_outcome not in('won','lost','reopen')
    or not public._crm_has_scope(opportunity_row.company_id,'crm.opportunities.write',coalesce(opportunity_row.assigned_user_id,opportunity_row.owner_user_id,opportunity_row.created_by),opportunity_row.team_id) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  if target_outcome='lost' and target_reason_id is null then raise exception 'crm_loss_reason_required'; end if;
  if target_outcome='reopen' then
    select * into stage_row from public.pipeline_stages where pipeline_id=opportunity_row.pipeline_id and stage_type='open' and active order by position limit 1;
    update public.opportunities set stage=stage_row.slug,pipeline_stage_id=stage_row.id,probability=stage_row.probability,
      forecast_category='potential',health='watch',closed_at=null,won_at=null,lost_at=null,reopened_at=now(),updated_by=auth.uid(),updated_at=now()
    where id=opportunity_row.id returning * into opportunity_row;
  else
    select * into stage_row from public.pipeline_stages where pipeline_id=opportunity_row.pipeline_id and stage_type=target_outcome and active order by position limit 1;
    if stage_row.id is null then raise exception 'crm_final_stage_missing'; end if;
    update public.opportunities set stage=stage_row.slug,pipeline_stage_id=stage_row.id,probability=stage_row.probability,
      forecast_category=target_outcome,health=target_outcome,closed_at=coalesce(target_closed_at,now()),
      won_at=case when target_outcome='won' then coalesce(target_closed_at,now()) else null end,
      lost_at=case when target_outcome='lost' then coalesce(target_closed_at,now()) else null end,
      actual_amount=coalesce(target_amount,amount),lost_reason_id=case when target_outcome='lost' then target_reason_id else null end,
      lost_reason=case when target_outcome='lost' then (select name from public.crm_loss_reasons where id=target_reason_id and company_id=opportunity_row.company_id) else null end,
      success_reason=case when target_outcome='won' then nullif(trim(target_comment),'') else success_reason end,
      close_comment=nullif(trim(target_comment),''),updated_by=auth.uid(),updated_at=now()
    where id=opportunity_row.id returning * into opportunity_row;
  end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,payload,created_by)
  values(opportunity_row.company_id,'opportunity',opportunity_row.id,'opportunity_'||target_outcome,
    case target_outcome when 'won' then 'Opportunité gagnée' when 'lost' then 'Opportunité perdue' else 'Opportunité rouverte' end,
    target_comment,jsonb_build_object('amount',opportunity_row.actual_amount,'reason_id',target_reason_id),auth.uid());
  return opportunity_row;
end
$$;

create or replace function public.link_crm_opportunity_document(target_opportunity_id uuid,target_document_id uuid,target_relation_type text default 'primary')
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;opportunity_row public.opportunities%rowtype;document_row public.documents%rowtype;relation_value text:=coalesce(nullif(target_relation_type,''),'primary');
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or relation_value not in('primary','variant','complement','replaced') then raise exception 'crm_forbidden' using errcode='42501'; end if;
  select * into opportunity_row from public.opportunities where id=target_opportunity_id and company_id=context_row.company_id;
  select * into document_row from public.documents where id=target_document_id and company_id=context_row.company_id and document_type in('quote','invoice','deposit_invoice','balance_invoice','credit_note');
  if opportunity_row.id is null or document_row.id is null then raise exception 'crm_link_target_not_found' using errcode='P0002'; end if;
  if not public._crm_has_scope(opportunity_row.company_id,'crm.opportunities.write',coalesce(opportunity_row.assigned_user_id,opportunity_row.owner_user_id,opportunity_row.created_by),opportunity_row.team_id)
    or not public._crm_has_scope(document_row.company_id,case when document_row.document_type='quote' then 'sales.quotes.read' else 'sales.invoices.read' end,coalesce(document_row.assigned_user_id,document_row.created_by),document_row.team_id) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  if document_row.document_type<>'quote' then relation_value:=null; end if;
  if relation_value='primary' then
    update public.documents set crm_relation_type='variant',updated_at=now()
    where company_id=context_row.company_id and opportunity_id=opportunity_row.id and document_type='quote' and crm_relation_type='primary' and id<>document_row.id;
  end if;
  update public.documents set opportunity_id=opportunity_row.id,crm_relation_type=relation_value,updated_at=now() where id=document_row.id returning * into document_row;
  perform public._recalculate_crm_opportunity_amount(opportunity_row.id,context_row.company_id);
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,related_type,related_id,payload,created_by)
  values(context_row.company_id,'opportunity',opportunity_row.id,'document_linked','Document lié',coalesce(document_row.number,'Brouillon'),'document',document_row.id,jsonb_build_object('document_type',document_row.document_type,'relation_type',relation_value),auth.uid());
  return jsonb_build_object('opportunity_id',opportunity_row.id,'document_id',document_row.id,'relation_type',relation_value);
end
$$;

-- La conversion conserve l'identité de l'opportunité et mémorise le prospect
-- d'origine avant de rattacher les objets au client cible.
create or replace function public.convert_crm_prospect(target_prospect_id uuid,target_existing_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;prospect public.clients%rowtype;target public.clients%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into prospect from public.clients where id=target_prospect_id and company_id=context_row.company_id for update;
  if prospect.id is null or prospect.relationship_type<>'prospect'
    or not public._crm_has_scope(prospect.company_id,'crm.prospects.write',coalesce(prospect.assigned_user_id,prospect.created_by),prospect.team_id)
    or not public._crm_has_scope(prospect.company_id,'clients.write',coalesce(prospect.assigned_user_id,prospect.created_by),prospect.team_id) then
    raise exception 'crm_invalid_prospect' using errcode='42501';
  end if;
  update public.opportunities set origin_prospect_id=coalesce(origin_prospect_id,prospect.id),updated_at=now() where company_id=prospect.company_id and client_id=prospect.id;
  if target_existing_client_id is null then
    update public.clients set relationship_type='client',crm_status='converted',converted_at=now(),updated_at=now() where id=prospect.id returning * into target;
  else
    select * into target from public.clients where id=target_existing_client_id and company_id=prospect.company_id and relationship_type='client' and active for update;
    if target.id is null or target.id=prospect.id
      or not public._crm_has_scope(target.company_id,'clients.write',coalesce(target.assigned_user_id,target.created_by),target.team_id) then raise exception 'crm_invalid_conversion_target'; end if;
    update public.client_contacts set is_primary=false where client_id=prospect.id and is_primary and exists(select 1 from public.client_contacts where client_id=target.id and is_primary);
    update public.client_contacts set client_id=target.id,updated_at=now() where client_id=prospect.id;
    update public.opportunities set client_id=target.id,updated_at=now() where client_id=prospect.id;
    update public.activities set client_id=target.id,updated_at=now() where client_id=prospect.id;
    update public.documents set client_id=target.id,updated_at=now() where client_id=prospect.id;
    update public.reminders set client_id=target.id,updated_at=now() where client_id=prospect.id;
    update public.clients set relationship_type='archived',crm_status='converted',converted_at=now(),active=false,updated_at=now() where id=prospect.id;
  end if;
  insert into public.crm_timeline_events(company_id,entity_type,entity_id,event_type,title,summary,related_type,related_id,created_by)
  values(prospect.company_id,'prospect',prospect.id,'prospect_converted','Prospect converti en client',coalesce(target.legal_name,target.trade_name,target.first_name||' '||target.last_name),'client',target.id,auth.uid());
  return jsonb_build_object('client_id',target.id,'prospect_id',prospect.id,'merged',target_existing_client_id is not null);
end
$$;

create or replace function public.create_crm_activity(target_payload jsonb)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.activities%rowtype;assigned_value uuid;team_value uuid;type_value text;status_value text;
  opportunity_value uuid:=nullif(target_payload->>'opportunity_id','')::uuid;
  client_value uuid:=nullif(target_payload->>'client_id','')::uuid;
  contact_value uuid:=nullif(target_payload->>'contact_id','')::uuid;
  document_value uuid:=nullif(target_payload->>'document_id','')::uuid;
begin
  select * into context_row from public._crm_context();
  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,auth.uid());
  team_value:=nullif(target_payload->>'team_id','')::uuid;
  if context_row.company_id is null or not public._crm_has_scope(context_row.company_id,'crm.activities.write',assigned_value,team_value) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  if opportunity_value is not null and not exists(select 1 from public.opportunities opportunity where opportunity.id=opportunity_value and opportunity.company_id=context_row.company_id and public._crm_has_scope(opportunity.company_id,'crm.opportunities.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id)) then raise exception 'crm_opportunity_forbidden' using errcode='42501'; end if;
  if client_value is not null and not exists(select 1 from public.clients client where client.id=client_value and client.company_id=context_row.company_id and public._crm_has_scope(client.company_id,case when client.relationship_type='prospect' then 'crm.prospects.read' else 'clients.read' end,coalesce(client.assigned_user_id,client.created_by),client.team_id)) then raise exception 'crm_party_forbidden' using errcode='42501'; end if;
  if contact_value is not null and not exists(select 1 from public.client_contacts contact where contact.id=contact_value and contact.company_id=context_row.company_id and (client_value is null or contact.client_id=client_value)) then raise exception 'crm_contact_invalid'; end if;
  if document_value is not null and not exists(select 1 from public.documents document where document.id=document_value and document.company_id=context_row.company_id) then raise exception 'crm_document_invalid'; end if;
  type_value:=coalesce(nullif(target_payload->>'activity_type',''),'task');
  status_value:=coalesce(nullif(target_payload->>'status',''),'todo');
  if nullif(trim(target_payload->>'subject'),'') is null then raise exception 'crm_activity_subject_required'; end if;
  insert into public.activities(company_id,opportunity_id,client_id,contact_id,document_id,activity_type,subject,description,scheduled_at,due_at,
    duration_minutes,priority,status,reminder_at,assigned_user_id,team_id,location,meeting_url,external_calendar,metadata,created_by,updated_by)
  values(context_row.company_id,opportunity_value,client_value,contact_value,document_value,type_value,trim(target_payload->>'subject'),
    nullif(target_payload->>'description',''),nullif(target_payload->>'scheduled_at','')::timestamptz,nullif(target_payload->>'due_at','')::timestamptz,
    greatest(0,coalesce(nullif(target_payload->>'duration_minutes','')::integer,0)),coalesce(nullif(target_payload->>'priority',''),'normal'),status_value,
    nullif(target_payload->>'reminder_at','')::timestamptz,assigned_value,team_value,nullif(target_payload->>'location',''),nullif(target_payload->>'meeting_url',''),
    nullif(target_payload->>'external_calendar',''),coalesce(target_payload->'metadata','{}'::jsonb),auth.uid(),auth.uid()) returning * into result;
  insert into public.crm_activity_links(company_id,activity_id,entity_type,entity_id,created_by,updated_by)
  select result.company_id,result.id,link.entity_type,link.entity_id,auth.uid(),auth.uid()
  from (values
    (case when exists(select 1 from public.clients where id=client_value and relationship_type='prospect') then 'prospect' else 'client' end,client_value),
    ('contact',contact_value),('opportunity',opportunity_value),
    (case when exists(select 1 from public.documents where id=document_value and document_type='quote') then 'quote' else 'invoice' end,document_value)
  ) link(entity_type,entity_id) where link.entity_id is not null
  on conflict(activity_id,entity_type,entity_id) do nothing;
  return result;
end
$$;

create or replace function public.save_crm_activity_v2(target_activity_id uuid,target_payload jsonb)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.activities%rowtype;assigned_value uuid;team_value uuid;
  opportunity_value uuid:=nullif(target_payload->>'opportunity_id','')::uuid;
  client_value uuid:=nullif(target_payload->>'client_id','')::uuid;
  contact_value uuid:=nullif(target_payload->>'contact_id','')::uuid;
  document_value uuid:=nullif(target_payload->>'document_id','')::uuid;
begin
  select * into context_row from public._crm_context();
  select * into result from public.activities where id=target_activity_id and company_id=context_row.company_id for update;
  if result.id is null or not public._crm_has_scope(result.company_id,'crm.activities.write',coalesce(result.assigned_user_id,result.created_by),result.team_id) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  assigned_value:=coalesce(nullif(target_payload->>'assigned_user_id','')::uuid,result.assigned_user_id,auth.uid());
  team_value:=coalesce(nullif(target_payload->>'team_id','')::uuid,result.team_id);
  if not public._crm_has_scope(result.company_id,'crm.activities.write',assigned_value,team_value) then raise exception 'crm_assignment_forbidden' using errcode='42501'; end if;
  if opportunity_value is not null and not exists(select 1 from public.opportunities opportunity where opportunity.id=opportunity_value and opportunity.company_id=result.company_id and public._crm_has_scope(opportunity.company_id,'crm.opportunities.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id)) then raise exception 'crm_opportunity_forbidden' using errcode='42501'; end if;
  if client_value is not null and not exists(select 1 from public.clients client where client.id=client_value and client.company_id=result.company_id and public._crm_has_scope(client.company_id,case when client.relationship_type='prospect' then 'crm.prospects.read' else 'clients.read' end,coalesce(client.assigned_user_id,client.created_by),client.team_id)) then raise exception 'crm_party_forbidden' using errcode='42501'; end if;
  if contact_value is not null and not exists(select 1 from public.client_contacts contact where contact.id=contact_value and contact.company_id=result.company_id and (client_value is null or contact.client_id=client_value)) then raise exception 'crm_contact_invalid'; end if;
  if document_value is not null and not exists(select 1 from public.documents document where document.id=document_value and document.company_id=result.company_id) then raise exception 'crm_document_invalid'; end if;
  if nullif(trim(target_payload->>'subject'),'') is null then raise exception 'crm_activity_subject_required'; end if;
  update public.activities set opportunity_id=opportunity_value,client_id=client_value,contact_id=contact_value,document_id=document_value,
    activity_type=coalesce(nullif(target_payload->>'activity_type',''),activity_type),subject=trim(target_payload->>'subject'),description=nullif(target_payload->>'description',''),
    due_at=nullif(target_payload->>'due_at','')::timestamptz,duration_minutes=greatest(0,coalesce(nullif(target_payload->>'duration_minutes','')::integer,0)),
    priority=coalesce(nullif(target_payload->>'priority',''),'normal'),status=coalesce(nullif(target_payload->>'status',''),'todo'),
    reminder_at=nullif(target_payload->>'reminder_at','')::timestamptz,assigned_user_id=assigned_value,team_id=team_value,
    location=nullif(target_payload->>'location',''),meeting_url=nullif(target_payload->>'meeting_url',''),updated_by=auth.uid(),updated_at=now()
  where id=result.id returning * into result;
  delete from public.crm_activity_links where activity_id=result.id and entity_type in('client','prospect','contact','opportunity','quote','invoice');
  insert into public.crm_activity_links(company_id,activity_id,entity_type,entity_id,created_by,updated_by)
  select result.company_id,result.id,link.entity_type,link.entity_id,auth.uid(),auth.uid()
  from (values
    (case when exists(select 1 from public.clients where id=client_value and company_id=result.company_id and relationship_type='prospect') then 'prospect' else 'client' end,client_value),
    ('contact',contact_value),('opportunity',opportunity_value),
    (case when exists(select 1 from public.documents where id=document_value and company_id=result.company_id and document_type='quote') then 'quote' else 'invoice' end,document_value)
  ) link(entity_type,entity_id) where link.entity_id is not null
  on conflict(activity_id,entity_type,entity_id) do nothing;
  return result;
end
$$;

create or replace function public.complete_crm_activity(target_activity_id uuid,target_result text default null,target_next_action text default null)
returns public.activities language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result public.activities%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into result from public.activities where id=target_activity_id and company_id=context_row.company_id for update;
  if result.id is null or not public._crm_has_scope(result.company_id,'crm.activities.write',coalesce(result.assigned_user_id,result.created_by),result.team_id) then
    raise exception 'crm_forbidden' using errcode='42501';
  end if;
  update public.activities set status='completed',completed_at=now(),result=nullif(trim(target_result),''),
    next_action=nullif(trim(target_next_action),''),updated_by=auth.uid(),updated_at=now()
  where id=result.id returning * into result;
  return result;
end
$$;

create or replace function public.complete_crm_activity_v2(target_activity_id uuid,target_result text default null,target_comment text default null,target_next_action text default null,target_next_action_at timestamptz default null,target_stage_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;activity_row public.activities%rowtype;next_row public.activities%rowtype;opportunity_row public.opportunities%rowtype;stage_row public.pipeline_stages%rowtype;
begin
  select * into context_row from public._crm_context();
  select * into activity_row from public.activities where id=target_activity_id and company_id=context_row.company_id for update;
  if activity_row.id is null or not public._crm_has_scope(activity_row.company_id,'crm.activities.write',coalesce(activity_row.assigned_user_id,activity_row.created_by),activity_row.team_id) then raise exception 'crm_forbidden' using errcode='42501'; end if;
  update public.activities set status='completed',completed_at=now(),result=nullif(trim(target_result),''),comment=nullif(trim(target_comment),''),
    next_action=nullif(trim(target_next_action),''),updated_by=auth.uid(),updated_at=now()
  where id=activity_row.id returning * into activity_row;
  if target_stage_id is not null and activity_row.opportunity_id is not null then
    select * into opportunity_row from public.opportunities where id=activity_row.opportunity_id and company_id=activity_row.company_id for update;
    select * into stage_row from public.pipeline_stages where id=target_stage_id and company_id=activity_row.company_id and pipeline_id=opportunity_row.pipeline_id and active;
    if opportunity_row.id is null or stage_row.id is null or stage_row.stage_type in('won','lost')
      or not public._crm_has_scope(opportunity_row.company_id,'crm.opportunities.write',coalesce(opportunity_row.assigned_user_id,opportunity_row.owner_user_id,opportunity_row.created_by),opportunity_row.team_id) then raise exception 'crm_stage_forbidden' using errcode='42501'; end if;
    update public.opportunities set pipeline_stage_id=stage_row.id,stage=stage_row.slug,probability=stage_row.probability,stage_entered_at=now(),updated_by=auth.uid(),updated_at=now() where id=opportunity_row.id;
  end if;
  if nullif(trim(target_next_action),'') is not null and target_next_action_at is not null then
    insert into public.activities(company_id,opportunity_id,client_id,contact_id,document_id,activity_type,subject,due_at,duration_minutes,priority,status,assigned_user_id,team_id,created_by,updated_by)
    values(activity_row.company_id,activity_row.opportunity_id,activity_row.client_id,activity_row.contact_id,activity_row.document_id,'task',trim(target_next_action),target_next_action_at,30,activity_row.priority,'todo',activity_row.assigned_user_id,activity_row.team_id,auth.uid(),auth.uid()) returning * into next_row;
  end if;
  return jsonb_build_object('activity',to_jsonb(activity_row),'next_activity',case when next_row.id is null then null else to_jsonb(next_row) end,'stage_id',target_stage_id);
end
$$;

create or replace function public.get_crm_pipeline_workspace(target_pipeline_id uuid default null,target_search text default null,target_filters jsonb default '{}'::jsonb,target_page integer default 1,target_page_size integer default 75)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;pipeline_uuid uuid;result jsonb;page_size integer:=least(100,greatest(10,coalesce(target_page_size,75)));
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.opportunities.read') then raise exception 'crm_access_denied' using errcode='42501'; end if;
  select id into pipeline_uuid from public.crm_pipelines where company_id=context_row.company_id and status='active'
    and (id=target_pipeline_id or target_pipeline_id is null and is_default) order by is_default desc,position limit 1;
  if pipeline_uuid is null then select id into pipeline_uuid from public.crm_pipelines where company_id=context_row.company_id and status='active' order by position limit 1; end if;
  with scoped as(
    select opportunity.*,client.legal_name,client.trade_name,client.first_name,client.last_name,client.relationship_type,
      stage.name stage_name,stage.color stage_color,stage.stage_type,source.name source_name,
      public._crm_has_scope(opportunity.company_id,'crm.amounts.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id) can_amount,
      coalesce(opportunity.actual_amount,opportunity.amount,0)*coalesce(opportunity.probability,0)/100 weighted_amount,
      extract(day from now()-coalesce(opportunity.stage_entered_at,opportunity.created_at))::integer days_in_stage,
      (select jsonb_build_object('id',activity.id,'subject',activity.subject,'due_at',coalesce(activity.due_at,activity.scheduled_at),'type',activity.activity_type)
       from public.activities activity where activity.company_id=opportunity.company_id and activity.opportunity_id=opportunity.id and activity.status in('todo','in_progress','postponed') order by coalesce(activity.due_at,activity.scheduled_at) nulls last limit 1) next_activity,
      (select count(*) from public.documents document where document.company_id=opportunity.company_id and document.opportunity_id=opportunity.id and document.document_type='quote') quote_count,
      row_number() over(partition by opportunity.pipeline_stage_id order by opportunity.expected_close_date nulls last,opportunity.created_at desc) stage_row,
      count(*) over() total_count
    from public.opportunities opportunity
    left join public.clients client on client.id=opportunity.client_id and client.company_id=opportunity.company_id
    left join public.pipeline_stages stage on stage.id=opportunity.pipeline_stage_id
    left join public.crm_sources source on source.id=opportunity.source_id
    where opportunity.company_id=context_row.company_id and opportunity.pipeline_id=pipeline_uuid and opportunity.archived_at is null
      and public._crm_has_scope(opportunity.company_id,'crm.opportunities.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id)
      and (nullif(trim(target_search),'') is null or to_tsvector('simple',coalesce(opportunity.name,'')||' '||coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')) @@ plainto_tsquery('simple',trim(target_search)))
      and (coalesce(target_filters->>'owner','')='' or opportunity.assigned_user_id=(target_filters->>'owner')::uuid)
      and (coalesce(target_filters->>'priority','')='' or opportunity.priority=target_filters->>'priority')
      and (coalesce(target_filters->>'forecast','')='' or opportunity.forecast_category=target_filters->>'forecast')
  ),paged as(select * from scoped where stage_row<=page_size order by stage_name,expected_close_date nulls last,created_at desc limit page_size*20)
  select jsonb_build_object(
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,
      'write',public.has_company_permission(context_row.company_id,'crm.opportunities.write'),
      'amounts',public.has_company_permission(context_row.company_id,'crm.amounts.read'),'margin',context_row.can_margin),
    'pipelines',coalesce((select jsonb_agg(to_jsonb(pipeline) order by pipeline.position,pipeline.name) from public.crm_pipelines pipeline where pipeline.company_id=context_row.company_id and pipeline.status<>'archived'),'[]'::jsonb),
    'pipeline',(select to_jsonb(pipeline) from public.crm_pipelines pipeline where pipeline.id=pipeline_uuid),
    'stages',coalesce((select jsonb_agg(to_jsonb(stage) order by stage.position,stage.id) from public.pipeline_stages stage where stage.company_id=context_row.company_id and stage.pipeline_id=pipeline_uuid and stage.active),'[]'::jsonb),
    'opportunities',coalesce((select jsonb_agg((to_jsonb(paged)-'stage_row'-'total_count'-'can_amount'-'weighted_amount'-'amount'-'estimated_amount'-'documentary_amount'-'actual_amount'-'recurring_amount')||jsonb_build_object(
      'amount',case when can_amount then amount else null end,'estimated_amount',case when can_amount then estimated_amount else null end,
      'documentary_amount',case when can_amount then documentary_amount else null end,'actual_amount',case when can_amount then actual_amount else null end,
      'recurring_amount',case when can_amount then recurring_amount else null end,'weighted_amount',case when can_amount then weighted_amount else null end
    ) order by expected_close_date nulls last,created_at desc) from paged),'[]'::jsonb),
    'summary',jsonb_build_object(
      'open_count',(select count(*) from scoped where stage_type='open'),
      'total_amount',coalesce((select round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) from scoped where stage_type='open'),0),
      'weighted_amount',coalesce((select round(sum(case when can_amount then weighted_amount else 0 end),2) from scoped where stage_type='open'),0),
      'closing_this_month',(select count(*) from scoped where stage_type='open' and expected_close_date>=date_trunc('month',current_date)::date and expected_close_date<(date_trunc('month',current_date)+interval '1 month')::date),
      'overdue',(select count(*) from scoped where stage_type='open' and expected_close_date<current_date),
      'total_count',coalesce((select max(total_count) from scoped),0)
    )
  ) into result;
  return result;
end
$$;

create or replace function public.get_crm_prospect_directory(target_search text default null,target_status text default null,target_owner uuid default null,target_page integer default 1,target_page_size integer default 50)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result jsonb;page_size integer:=least(100,greatest(10,coalesce(target_page_size,50)));offset_rows integer;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.prospects.read') then raise exception 'crm_access_denied' using errcode='42501'; end if;
  offset_rows:=greatest(0,(coalesce(target_page,1)-1)*page_size);
  with scoped as(
    select client.*,source.name source_name,
      (select count(*) from public.opportunities opportunity where opportunity.company_id=client.company_id and opportunity.client_id=client.id and opportunity.archived_at is null) opportunity_count,
      (select coalesce(sum(case when public._crm_has_scope(opportunity.company_id,'crm.amounts.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id) then opportunity.amount else 0 end),0) from public.opportunities opportunity where opportunity.company_id=client.company_id and opportunity.client_id=client.id and opportunity.archived_at is null) potential_amount,
      (select jsonb_build_object('id',activity.id,'subject',activity.subject,'due_at',coalesce(activity.due_at,activity.scheduled_at),'type',activity.activity_type) from public.activities activity where activity.company_id=client.company_id and activity.client_id=client.id and activity.status in('todo','in_progress','postponed') order by coalesce(activity.due_at,activity.scheduled_at) nulls last limit 1) next_activity,
      count(*) over() total_count
    from public.clients client left join public.crm_sources source on source.id=client.crm_source_id
    where client.company_id=context_row.company_id and client.relationship_type='prospect' and client.active
      and public._crm_has_scope(client.company_id,'crm.prospects.read',coalesce(client.assigned_user_id,client.created_by),client.team_id)
      and (target_status is null or target_status='' or client.crm_status=target_status)
      and (target_owner is null or client.assigned_user_id=target_owner)
      and (nullif(trim(target_search),'') is null or to_tsvector('simple',coalesce(client.legal_name,'')||' '||coalesce(client.trade_name,'')||' '||coalesce(client.first_name,'')||' '||coalesce(client.last_name,'')||' '||coalesce(client.email,'')) @@ plainto_tsquery('simple',trim(target_search)))
  ),paged as(select * from scoped order by crm_score desc,created_at desc offset offset_rows limit page_size)
  select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(paged)-'total_count' order by crm_score desc,created_at desc),'[]'::jsonb),
    'total',coalesce(max(total_count),0),'page',greatest(1,coalesce(target_page,1)),'page_size',page_size,
    'permissions',jsonb_build_object('manage',context_row.can_manage,'view_all',context_row.can_view_all,
      'write',public.has_company_permission(context_row.company_id,'crm.prospects.write'))) into result from paged;
  return result;
end
$$;

create or replace function public.get_crm_activity_workspace(target_view text default 'list',target_filter text default 'upcoming',target_owner uuid default null,target_start date default null,target_end date default null,target_page integer default 1,target_page_size integer default 80)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result jsonb;date_start date:=coalesce(target_start,current_date-30);date_end date:=coalesce(target_end,current_date+60);
  page_size integer:=least(200,greatest(10,coalesce(target_page_size,80)));offset_rows integer;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.activities.read') then raise exception 'crm_access_denied' using errcode='42501'; end if;
  if date_end<date_start then raise exception 'crm_invalid_period'; end if;
  offset_rows:=greatest(0,(coalesce(target_page,1)-1)*page_size);
  with scoped as(
    select activity.*,client.legal_name,client.trade_name,client.first_name,client.last_name,client.relationship_type,
      opportunity.name opportunity_name,contact.first_name contact_first_name,contact.last_name contact_last_name,
      document.number document_number,document.document_type,
      count(*) over() total_count
    from public.activities activity
    left join public.clients client on client.id=activity.client_id and client.company_id=activity.company_id
    left join public.opportunities opportunity on opportunity.id=activity.opportunity_id and opportunity.company_id=activity.company_id
    left join public.client_contacts contact on contact.id=activity.contact_id and contact.company_id=activity.company_id
    left join public.documents document on document.id=activity.document_id and document.company_id=activity.company_id
    where activity.company_id=context_row.company_id
      and public._crm_has_scope(activity.company_id,'crm.activities.read',coalesce(activity.assigned_user_id,activity.created_by),activity.team_id)
      and (target_owner is null or activity.assigned_user_id=target_owner)
      and coalesce(activity.due_at,activity.scheduled_at,activity.created_at)::date between date_start and date_end
      and (coalesce(target_filter,'all')='all'
        or target_filter='today' and coalesce(activity.due_at,activity.scheduled_at)::date=current_date
        or target_filter='upcoming' and activity.status not in('completed','cancelled') and coalesce(activity.due_at,activity.scheduled_at)>=now()
        or target_filter='overdue' and activity.status not in('completed','cancelled') and coalesce(activity.due_at,activity.scheduled_at)<now()
        or target_filter='completed' and activity.status='completed')
  ),paged as(
    select * from scoped order by coalesce(due_at,scheduled_at,created_at),priority desc,id offset offset_rows limit page_size
  )
  select jsonb_build_object(
    'view',coalesce(target_view,'list'),'filter',coalesce(target_filter,'all'),'start',date_start,'end',date_end,
    'rows',coalesce((select jsonb_agg(to_jsonb(paged)-'total_count' order by coalesce(due_at,scheduled_at,created_at),id) from paged),'[]'::jsonb),
    'total',coalesce((select max(total_count) from scoped),0),'page',greatest(1,coalesce(target_page,1)),'page_size',page_size,
    'permissions',jsonb_build_object(
      'write',public.has_company_permission(context_row.company_id,'crm.activities.write'),
      'team',public.has_company_permission(context_row.company_id,'crm.team_activities.read')
    ),
    'counts',jsonb_build_object(
      'overdue',(select count(*) from scoped where status not in('completed','cancelled') and coalesce(due_at,scheduled_at)<now()),
      'today',(select count(*) from scoped where coalesce(due_at,scheduled_at)::date=current_date),
      'completed',(select count(*) from scoped where status='completed')
    )
  ) into result;
  return result;
end
$$;

create or replace function public.get_crm_reports(target_start date default date_trunc('month',current_date)::date,target_end date default current_date,target_pipeline_id uuid default null,target_owner uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record;result jsonb;period_days integer;previous_start date;previous_end date;
begin
  select * into context_row from public._crm_context();
  if context_row.company_id is null or not public.has_company_permission(context_row.company_id,'crm.reports.read') then raise exception 'crm_reports_forbidden' using errcode='42501'; end if;
  if target_start is null or target_end is null or target_end<target_start then raise exception 'crm_invalid_period'; end if;
  period_days:=(target_end-target_start)+1;
  previous_start:=target_start-period_days;
  previous_end:=target_start-1;
  with visible_opportunities as(
    select opportunity.*,stage.name stage_name,stage.color stage_color,stage.position stage_position,stage.stage_type,
      source.name source_name,client.id party_id,coalesce(client.trade_name,client.legal_name,concat_ws(' ',client.first_name,client.last_name),'Non renseigné') party_name,
      public._crm_has_scope(opportunity.company_id,'crm.amounts.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id) can_amount,
      public._crm_has_scope(opportunity.company_id,'crm.performance.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id) can_performance
    from public.opportunities opportunity
    left join public.pipeline_stages stage on stage.id=opportunity.pipeline_stage_id
    left join public.crm_sources source on source.id=opportunity.source_id
    left join public.clients client on client.id=opportunity.client_id and client.company_id=opportunity.company_id
    where opportunity.company_id=context_row.company_id and opportunity.archived_at is null
      and (target_pipeline_id is null or opportunity.pipeline_id=target_pipeline_id)
      and (target_owner is null or opportunity.assigned_user_id=target_owner)
      and public._crm_has_scope(opportunity.company_id,'crm.reports.read',coalesce(opportunity.assigned_user_id,opportunity.owner_user_id,opportunity.created_by),opportunity.team_id)
  ),period_opportunities as(
    select * from visible_opportunities where coalesce(closed_at::date,created_at::date) between target_start and target_end
  ),previous_opportunities as(
    select * from visible_opportunities where coalesce(closed_at::date,created_at::date) between previous_start and previous_end
  ),visible_documents as(
    select document.*,opportunity.can_amount
    from public.documents document join visible_opportunities opportunity on opportunity.id=document.opportunity_id
    where document.company_id=context_row.company_id and document.archived_at is null
  ),visible_activities as(
    select activity.* from public.activities activity where activity.company_id=context_row.company_id
      and public._crm_has_scope(activity.company_id,'crm.activities.read',coalesce(activity.assigned_user_id,activity.created_by),activity.team_id)
      and (target_owner is null or activity.assigned_user_id=target_owner)
  )
  select jsonb_build_object(
    'period',jsonb_build_object('start',target_start,'end',target_end),
    'permissions',jsonb_build_object(
      'export',public.has_company_permission(context_row.company_id,'crm.reports.export'),
      'amounts',public.has_company_permission(context_row.company_id,'crm.amounts.read'),
      'performance',public.has_company_permission(context_row.company_id,'crm.performance.read'),
      'team_activities',public.has_company_permission(context_row.company_id,'crm.team_activities.read')
    ),
    'metrics',jsonb_build_object(
      'pipeline_count',(select count(*) from visible_opportunities where stage_type='open'),
      'pipeline_amount',coalesce((select round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) from visible_opportunities where stage_type='open'),0),
      'pipeline_weighted',coalesce((select round(sum(case when can_amount then coalesce(amount,0)*coalesce(probability,0)/100 else 0 end),2) from visible_opportunities where stage_type='open'),0),
      'won_amount',coalesce((select round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end),2) from period_opportunities where won_at is not null),0),
      'invoiced_ht',coalesce((select round(sum(case when can_amount then total_excl_tax else 0 end),2) from visible_documents where document_type in('invoice','deposit_invoice','balance_invoice') and status not in('draft','cancelled','archived') and issue_date between target_start and target_end),0),
      'collected_ttc',coalesce((select round(sum(allocation.amount),2) from public.payment_allocations allocation join visible_documents document on document.id=allocation.document_id where allocation.created_at::date between target_start and target_end and document.can_amount),0),
      'average_ticket',coalesce((select round(avg(case when can_amount then coalesce(actual_amount,amount,0) end),2) from period_opportunities where won_at is not null and can_amount),0),
      'average_cycle_days',coalesce((select round(avg(extract(epoch from coalesce(closed_at,now())-created_at)/86400)::numeric,1) from period_opportunities where closed_at is not null),0),
      'opportunity_count',(select count(*) from period_opportunities),
      'blocked_count',(select count(*) from visible_opportunities where stage_type='open' and health in('blocked','at_risk')),
      'without_activity_count',(select count(*) from visible_opportunities opportunity where stage_type='open' and not exists(select 1 from public.activities activity where activity.company_id=opportunity.company_id and activity.opportunity_id=opportunity.id)),
      'without_next_action_count',(select count(*) from visible_opportunities opportunity where stage_type='open' and opportunity.next_action_at is null and not exists(select 1 from public.activities activity where activity.company_id=opportunity.company_id and activity.opportunity_id=opportunity.id and activity.status in('todo','in_progress','postponed') and coalesce(activity.due_at,activity.scheduled_at)>=now())),
      'overdue_close_count',(select count(*) from visible_opportunities where stage_type='open' and expected_close_date<current_date)
    ),
    'comparison',jsonb_build_object(
      'start',previous_start,'end',previous_end,
      'won_count',(select count(*) from previous_opportunities where won_at is not null),
      'won_amount',coalesce((select round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end),2) from previous_opportunities where won_at is not null),0),
      'lost_count',(select count(*) from previous_opportunities where lost_at is not null),
      'conversion_rate',coalesce((select round(100.0*count(*) filter(where won_at is not null)/nullif(count(*) filter(where won_at is not null or lost_at is not null),0),1) from previous_opportunities),0)
    ),
    'pipeline',coalesce((select jsonb_agg(jsonb_build_object('stage_id',stage.id,'stage',stage.name,'color',stage.color,'count',coalesce(stats.count,0),'amount',coalesce(stats.amount,0),'weighted',coalesce(stats.weighted,0),'average_age_days',coalesce(stats.average_age_days,0)) order by stage.position)
      from public.pipeline_stages stage left join lateral(
        select count(*) count,round(sum(case when opportunity.can_amount then coalesce(opportunity.amount,0) else 0 end),2) amount,
          round(sum(case when opportunity.can_amount then coalesce(opportunity.amount,0)*coalesce(opportunity.probability,0)/100 else 0 end),2) weighted,
          round(avg(extract(epoch from now()-coalesce(opportunity.stage_entered_at,opportunity.created_at))/86400)::numeric,1) average_age_days
        from visible_opportunities opportunity where opportunity.pipeline_stage_id=stage.id
      )stats on true where stage.company_id=context_row.company_id and stage.active and (target_pipeline_id is null or stage.pipeline_id=target_pipeline_id)),'[]'::jsonb),
    'outcomes',jsonb_build_object(
      'won_count',(select count(*) from period_opportunities where won_at is not null),
      'won_amount',coalesce((select round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end),2) from period_opportunities where won_at is not null),0),
      'lost_count',(select count(*) from period_opportunities where lost_at is not null),
      'conversion_rate',coalesce((select round(100.0*count(*) filter(where won_at is not null)/nullif(count(*) filter(where won_at is not null or lost_at is not null),0),1) from period_opportunities),0),
      'average_cycle_days',coalesce((select round(avg(extract(epoch from closed_at-created_at)/86400)::numeric,1) from period_opportunities where closed_at is not null),0)
    ),
    'collaborators',coalesce((select jsonb_agg(jsonb_build_object('user_id',assigned_user_id,'open_count',open_count,'won_count',won_count,'lost_count',lost_count,'amount',amount,'conversion_rate',round(100.0*won_count/nullif(won_count+lost_count,0),1)) order by amount desc)
      from(select assigned_user_id,count(*) filter(where stage_type='open') open_count,count(*) filter(where won_at is not null) won_count,
        count(*) filter(where lost_at is not null) lost_count,round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end) filter(where won_at is not null),2) amount
        from period_opportunities where can_performance group by assigned_user_id)stat),'[]'::jsonb),
    'loss_reasons',coalesce((select jsonb_agg(jsonb_build_object('reason',coalesce(reason.name,opportunity.lost_reason,'Autre'),'count',opportunity.count) order by opportunity.count desc)
      from(select lost_reason_id,lost_reason,count(*) count from period_opportunities where lost_at is not null group by lost_reason_id,lost_reason)opportunity
      left join public.crm_loss_reasons reason on reason.id=opportunity.lost_reason_id),'[]'::jsonb),
    'sources',coalesce((select jsonb_agg(jsonb_build_object('source',coalesce(source_name,'Non renseignée'),'opportunities',count,'won',won,'amount',amount,'conversion_rate',round(100.0*won/nullif(count,0),1)) order by amount desc)
      from(select source_name,count(*) count,count(*) filter(where won_at is not null) won,round(sum(case when can_amount and won_at is not null then coalesce(actual_amount,amount,0) else 0 end),2) amount from period_opportunities group by source_name)stat),'[]'::jsonb),
    'activities',jsonb_build_object(
      'created',(select count(*) from visible_activities where created_at::date between target_start and target_end),
      'completed',(select count(*) from visible_activities where completed_at::date between target_start and target_end),
      'overdue',(select count(*) from visible_activities where status not in('completed','cancelled') and coalesce(due_at,scheduled_at)<now()),
      'planned',(select count(*) from visible_activities where coalesce(due_at,scheduled_at)::date between target_start and target_end),
      'completion_rate',coalesce((select round(100.0*count(*) filter(where status='completed')/nullif(count(*),0),1) from visible_activities where coalesce(due_at,scheduled_at)::date between target_start and target_end),0),
      'by_type',coalesce((select jsonb_agg(jsonb_build_object('type',activity_type,'count',count) order by count desc) from(select activity_type,count(*) count from visible_activities where created_at::date between target_start and target_end group by activity_type)types),'[]'::jsonb)
    ),
    'quotes',jsonb_build_object(
      'created',(select count(*) from visible_documents where document_type='quote' and created_at::date between target_start and target_end),
      'sent',(select count(*) from visible_documents where document_type='quote' and sent_at::date between target_start and target_end),
      'accepted',(select count(*) from visible_documents where document_type='quote' and status='accepted' and coalesce(accepted_at,updated_at)::date between target_start and target_end),
      'refused',(select count(*) from visible_documents where document_type='quote' and status in('refused','rejected') and updated_at::date between target_start and target_end),
      'expired',(select count(*) from visible_documents where document_type='quote' and status not in('accepted','refused','rejected','cancelled','archived') and validity_date<current_date),
      'acceptance_rate',coalesce((select round(100.0*count(*) filter(where status='accepted')/nullif(count(*) filter(where status in('accepted','refused','rejected')),0),1) from visible_documents where document_type='quote' and updated_at::date between target_start and target_end),0),
      'average_amount',coalesce((select round(avg(total_excl_tax),2) from visible_documents where document_type='quote' and created_at::date between target_start and target_end and can_amount),0),
      'opportunities_without_quote',(select count(*) from visible_opportunities opportunity where opportunity.stage_type='open' and not exists(select 1 from public.documents document where document.company_id=opportunity.company_id and document.opportunity_id=opportunity.id and document.document_type='quote' and document.archived_at is null))
    ),
    'forecast',jsonb_build_object(
      'gross',coalesce((select round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) from visible_opportunities where stage_type='open' and expected_close_date between target_start and target_end),0),
      'weighted',coalesce((select round(sum(case when can_amount then coalesce(amount,0)*coalesce(probability,0)/100 else 0 end),2) from visible_opportunities where stage_type='open' and expected_close_date between target_start and target_end),0),
      'probable',coalesce((select round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) from visible_opportunities where forecast_category='probable' and expected_close_date between target_start and target_end),0),
      'committed',coalesce((select round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) from visible_opportunities where forecast_category='commit' and expected_close_date between target_start and target_end),0),
      'won',coalesce((select round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end),2) from period_opportunities where won_at is not null),0),
      'lost',coalesce((select round(sum(case when can_amount then coalesce(actual_amount,amount,0) else 0 end),2) from period_opportunities where lost_at is not null),0),
      'buckets',coalesce((select jsonb_agg(jsonb_build_object('category',forecast_category,'count',count,'amount',amount,'weighted',weighted) order by array_position(array['commit','probable','potential','unqualified','won','lost'],forecast_category)) from(
        select forecast_category,count(*) count,round(sum(case when can_amount then coalesce(amount,0) else 0 end),2) amount,round(sum(case when can_amount then coalesce(amount,0)*coalesce(probability,0)/100 else 0 end),2) weighted
        from visible_opportunities where expected_close_date between target_start and target_end group by forecast_category
      )bucket),'[]'::jsonb)
    )
  ) into result;
  return result;
end
$$;

do $amount_backfill$
declare opportunity_row record;
begin
  for opportunity_row in select id,company_id from public.opportunities loop
    perform public._recalculate_crm_opportunity_amount(opportunity_row.id,opportunity_row.company_id);
  end loop;
end
$amount_backfill$;

revoke all on function public.recalculate_crm_opportunity_amount(uuid) from public,anon;
revoke all on function public.get_crm_party_picker(text,integer,text) from public,anon;
revoke all on function public.create_crm_party(jsonb) from public,anon;
revoke all on function public.save_crm_opportunity_v2(uuid,jsonb) from public,anon;
revoke all on function public.save_crm_activity_v2(uuid,jsonb) from public,anon;
revoke all on function public.link_crm_opportunity_document(uuid,uuid,text) from public,anon;
revoke all on function public.complete_crm_activity_v2(uuid,text,text,text,timestamptz,uuid) from public,anon;
grant execute on function public.recalculate_crm_opportunity_amount(uuid) to authenticated;
grant execute on function public.get_crm_party_picker(text,integer,text) to authenticated;
grant execute on function public.create_crm_party(jsonb) to authenticated;
grant execute on function public.save_crm_opportunity_v2(uuid,jsonb) to authenticated;
grant execute on function public.save_crm_activity_v2(uuid,jsonb) to authenticated;
grant execute on function public.link_crm_opportunity_document(uuid,uuid,text) to authenticated;
grant execute on function public.complete_crm_activity_v2(uuid,text,text,text,timestamptz,uuid) to authenticated;
grant select(estimated_amount,documentary_amount,amount_source,origin_prospect_id,tags) on public.opportunities to authenticated;
grant select(crm_relation_type,crm_replaced_by_id) on public.documents to authenticated;

alter table public.company_fiscal_configurations alter column application_version set default '0.9.0-compliance.47';
alter table public.company_fiscal_configurations alter column schema_version set default '202607270092';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.47',schema_version='202607270092',updated_at=now()
where application_version is distinct from '0.9.0-compliance.47' or schema_version is distinct from '202607270092';

commit;
