begin;

-- Phase 8 - privacy, least-privilege roles and controlled fiscal activation.
-- This migration is additive. It does not certify the software and it never
-- enables production fiscal mode automatically.

alter table public.company_members drop constraint if exists company_members_role_check;
alter table public.company_members add constraint company_members_role_check
  check(role in('owner','admin','billing','sales','accounting','read_only','auditor','member')) not valid;

create or replace function public.has_company_permission(target_company_id uuid,target_permission text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.company_members member
    where member.company_id=target_company_id and member.user_id=auth.uid()
      and case
        when member.role in('owner','admin') then true
        when member.permissions ? target_permission then lower(member.permissions->>target_permission)='true'
        when member.role='billing' then target_permission=any(array[
          'application_read','sales_document_write','finalize_invoice','record_payment','manage_reminder','fiscal_read'
        ])
        when member.role='sales' then target_permission=any(array[
          'application_read','sales_document_write','finalize_quote','manage_customer','manage_opportunity'
        ])
        when member.role='accounting' then target_permission=any(array[
          'application_read','finalize_invoice','create_credit_note','record_payment','fiscal_read',
          'create_closure','create_archive','electronic_invoice_manage','compliance_view'
        ])
        when member.role='auditor' then target_permission=any(array[
          'application_read','fiscal_read','compliance_view','personal_data_audit'
        ])
        when member.role='read_only' then target_permission='application_read'
        -- Legacy members keep ordinary application access but receive no
        -- sensitive fiscal permission implicitly.
        when member.role='member' then target_permission='application_read'
        else false
      end
  )
$$;
revoke all on function public.has_company_permission(uuid,text) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

create table if not exists public.company_compliance_evidence(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  evidence_type text not null check(evidence_type in(
    'backup_restore_test','release_test_report','security_review','legal_validation',
    'kms_key_validation','electronic_profiles_validation','platform_contract','other'
  )),
  title text not null,
  status text not null default 'claimed' check(status in('claimed','verified','expired','rejected')),
  artifact_path text,
  artifact_sha256 text,
  external_reference text,
  performed_at timestamptz,
  expires_at timestamptz,
  recorded_by uuid,
  recorded_at timestamptz not null default now(),
  verified_by uuid,
  verified_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  check((status='verified' and verified_at is not null) or status<>'verified')
);

create table if not exists public.compliance_anomalies(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  anomaly_type text not null,
  severity text not null check(severity in('info','warning','error','critical')),
  source text not null,
  entity_type text,
  entity_id uuid,
  detected_hash text not null,
  details jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default now(),
  detected_by uuid,
  application_version text not null,
  schema_version text not null,
  unique(company_id,anomaly_type,detected_hash)
);

create table if not exists public.compliance_anomaly_resolutions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  anomaly_id uuid not null references public.compliance_anomalies(id) on delete restrict,
  resolution text not null,
  evidence_id uuid references public.company_compliance_evidence(id) on delete restrict,
  resolved_by uuid,
  resolved_at timestamptz not null default now(),
  unique(anomaly_id)
);

create table if not exists public.compliance_integrity_checks(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  status text not null check(status in('valid','anomaly')),
  checked_at timestamptz not null default now(),
  checked_by uuid,
  checked_events bigint not null default 0,
  invalid_archives bigint not null default 0,
  signature_verification text not null,
  report jsonb not null,
  report_sha256 text not null,
  application_version text not null,
  schema_version text not null,
  unique(company_id,report_sha256)
);

create table if not exists public.data_subject_requests(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  request_type text not null check(request_type in('access','rectification','erasure','restriction','portability','objection','other')),
  subject_kind text not null check(subject_kind in('user','client','prospect','supplier','contact','other')),
  subject_reference text not null,
  received_at timestamptz not null default now(),
  identity_verified_at timestamptz,
  due_at timestamptz not null,
  status text not null default 'received' check(status in('received','identity_check','in_progress','partially_fulfilled','fulfilled','refused','cancelled')),
  legal_basis text,
  response_summary text,
  closed_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.data_subject_request_items(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  request_id uuid not null references public.data_subject_requests(id) on delete restrict,
  data_category text not null,
  entity_type text,
  entity_id uuid,
  decision text not null check(decision in('export','rectify','delete','anonymize','retain','restrict','not_found')),
  decision_reason text not null,
  legal_hold boolean not null default false,
  processed_at timestamptz,
  processed_by uuid,
  evidence_hash text,
  created_at timestamptz not null default now()
);

create table if not exists public.company_retention_rules(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  data_category text not null,
  retention_months integer check(retention_months is null or retention_months>0),
  trigger_event text not null,
  legal_basis text not null,
  action_after_expiry text not null check(action_after_expiry in('review','delete','anonymize','archive','legal_hold')),
  validated_by text,
  validated_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,data_category)
);

create table if not exists public.company_software_certifications(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  certification_type text not null,
  certificate_number text not null,
  certification_body text not null,
  issued_at date not null,
  expires_at date,
  application_version_from text not null,
  application_version_to text,
  evidence_path text,
  evidence_sha256 text,
  status text not null default 'pending' check(status in('pending','verified','expired','revoked')),
  verified_at timestamptz,
  recorded_by uuid,
  recorded_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  unique(company_id,certification_type,certificate_number),
  check((status='verified' and verified_at is not null) or status<>'verified')
);

do $$ declare table_name text; begin
  foreach table_name in array array[
    'company_compliance_evidence','compliance_anomalies','compliance_anomaly_resolutions','compliance_integrity_checks',
    'data_subject_requests','data_subject_request_items','company_retention_rules',
    'company_software_certifications'
  ] loop
    execute format('alter table public.%I enable row level security',table_name);
    execute format('drop policy if exists %I on public.%I',table_name||'_select',table_name);
    execute format(
      'create policy %I on public.%I for select to authenticated using(public.has_company_permission(company_id,''compliance_view''))',
      table_name||'_select',table_name
    );
    execute format('revoke all on public.%I from anon,authenticated',table_name);
    execute format('grant select on public.%I to authenticated',table_name);
  end loop;
end $$;

drop trigger if exists company_retention_rules_set_updated_at on public.company_retention_rules;
create trigger company_retention_rules_set_updated_at before update on public.company_retention_rules
for each row execute function public.set_current_timestamp_updated_at();

-- Immutable evidence and anomaly history. Corrections are separate rows.
drop trigger if exists company_compliance_evidence_immutable on public.company_compliance_evidence;
create trigger company_compliance_evidence_immutable before update or delete on public.company_compliance_evidence
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists compliance_anomalies_immutable on public.compliance_anomalies;
create trigger compliance_anomalies_immutable before update or delete on public.compliance_anomalies
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists compliance_anomaly_resolutions_immutable on public.compliance_anomaly_resolutions;
create trigger compliance_anomaly_resolutions_immutable before update or delete on public.compliance_anomaly_resolutions
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists compliance_integrity_checks_immutable on public.compliance_integrity_checks;
create trigger compliance_integrity_checks_immutable before update or delete on public.compliance_integrity_checks
for each row execute function public.protect_immutable_fiscal_row();
drop trigger if exists company_software_certifications_immutable on public.company_software_certifications;
create trigger company_software_certifications_immutable before update or delete on public.company_software_certifications
for each row execute function public.protect_immutable_fiscal_row();

create or replace function public.log_company_access_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare company_value uuid; member_value uuid; operation_value text;
begin
  company_value:=coalesce(new.company_id,old.company_id);
  member_value:=coalesce(new.user_id,old.user_id);
  operation_value:=lower(tg_op);
  perform public._append_fiscal_event(company_value,'user_permission_changed','company_member',member_value,
    clock_timestamp(),jsonb_build_object(
      'operation',operation_value,
      'previous_role',case when tg_op in('UPDATE','DELETE') then old.role else null end,
      'new_role',case when tg_op in('INSERT','UPDATE') then new.role else null end,
      'previous_permissions',case when tg_op in('UPDATE','DELETE') then old.permissions else null end,
      'new_permissions',case when tg_op in('INSERT','UPDATE') then new.permissions else null end
    ),'database_trigger','{}'::jsonb);
  if tg_op='DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function public.log_company_access_change() from public,anon,authenticated;
create or replace function public.guard_company_owner_access()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='DELETE' and old.role='owner' then raise exception 'owner_cannot_be_deleted' using errcode='42501'; end if;
  if tg_op='UPDATE' and old.role is distinct from new.role and (old.role='owner' or new.role='owner') then
    raise exception 'owner_role_requires_dedicated_transfer' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function public.guard_company_owner_access() from public,anon,authenticated;
drop trigger if exists company_members_guard_owner on public.company_members;
create trigger company_members_guard_owner before update of role or delete on public.company_members
for each row execute function public.guard_company_owner_access();
drop trigger if exists company_members_log_access_change on public.company_members;
create trigger company_members_log_access_change after insert or update of role,permissions or delete on public.company_members
for each row execute function public.log_company_access_change();

create or replace function public.guard_sensitive_document_transition()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare permission_name text;
begin
  if auth.uid() is null or old.finalized_at is not null or new.finalized_at is null then return new; end if;
  permission_name:=case
    when new.document_type='quote' then 'finalize_quote'
    when new.document_type='credit_note' then 'create_credit_note'
    else 'finalize_invoice'
  end;
  if not public.has_company_permission(new.company_id,permission_name) then
    raise exception 'missing_permission:%',permission_name using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function public.guard_sensitive_document_transition() from public,anon,authenticated;
drop trigger if exists documents_guard_sensitive_transition on public.documents;
create trigger documents_guard_sensitive_transition before update of finalized_at on public.documents
for each row execute function public.guard_sensitive_document_transition();

create or replace function public.guard_payment_ledger_insert()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is not null and not public.has_company_permission(new.company_id,'record_payment') then
    raise exception 'missing_permission:record_payment' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function public.guard_payment_ledger_insert() from public,anon,authenticated;
drop trigger if exists payments_guard_permission on public.payments;
create trigger payments_guard_permission before insert on public.payments
for each row execute function public.guard_payment_ledger_insert();

-- Restrict fiscal registers to explicitly authorised roles.
drop policy if exists company_fiscal_configurations_select on public.company_fiscal_configurations;
create policy company_fiscal_configurations_select on public.company_fiscal_configurations for select to authenticated
using(public.has_company_permission(company_id,'compliance_view'));
drop policy if exists fiscal_event_heads_select on public.fiscal_event_heads;
create policy fiscal_event_heads_select on public.fiscal_event_heads for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
drop policy if exists fiscal_events_select on public.fiscal_events;
create policy fiscal_events_select on public.fiscal_events for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
drop policy if exists fiscal_closures_select on public.fiscal_closures;
create policy fiscal_closures_select on public.fiscal_closures for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
drop policy if exists fiscal_archives_select on public.fiscal_archives;
create policy fiscal_archives_select on public.fiscal_archives for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
drop policy if exists fiscal_archive_items_select on public.fiscal_archive_items;
create policy fiscal_archive_items_select on public.fiscal_archive_items for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
drop policy if exists fiscal_archive_exports_select on public.fiscal_archive_exports;
create policy fiscal_archive_exports_select on public.fiscal_archive_exports for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));

create or replace function public.set_company_member_access(
  target_company_id uuid,target_user_id uuid,target_role text,target_permissions jsonb default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare current_member public.company_members%rowtype; updated_member public.company_members%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  select * into current_member from public.company_members
  where company_id=target_company_id and user_id=target_user_id for update;
  if current_member.user_id is null then raise exception 'member_not_found' using errcode='P0002'; end if;
  if current_member.role='owner' and target_role is distinct from 'owner' then
    raise exception 'owner_role_requires_dedicated_transfer' using errcode='42501';
  end if;
  if current_member.role<>'owner' and target_role='owner' then
    raise exception 'owner_role_requires_dedicated_transfer' using errcode='42501';
  end if;
  update public.company_members set role=target_role,
    permissions=coalesce(target_permissions,current_member.permissions),updated_at=now()
  where company_id=target_company_id and user_id=target_user_id returning * into updated_member;
  return jsonb_build_object('company_id',updated_member.company_id,'user_id',updated_member.user_id,
    'role',updated_member.role,'permissions',updated_member.permissions,'updated_at',updated_member.updated_at);
end
$$;

create or replace function public.register_compliance_evidence(
  target_company_id uuid,target_evidence_type text,target_title text,target_artifact_path text default null,
  target_artifact_sha256 text default null,target_external_reference text default null,
  target_performed_at timestamptz default now(),target_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id uuid:=gen_random_uuid();
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.company_compliance_evidence(
    id,company_id,evidence_type,title,status,artifact_path,artifact_sha256,external_reference,
    performed_at,recorded_by,metadata
  ) values(
    result_id,target_company_id,target_evidence_type,trim(target_title),'claimed',nullif(trim(target_artifact_path),''),
    nullif(lower(trim(target_artifact_sha256)),''),nullif(trim(target_external_reference),''),
    target_performed_at,auth.uid(),coalesce(target_metadata,'{}'::jsonb)
  );
  perform public._append_fiscal_event(target_company_id,'compliance_evidence_recorded','compliance_evidence',result_id,
    clock_timestamp(),jsonb_build_object('evidence_type',target_evidence_type,'status','claimed',
      'artifact_sha256',nullif(lower(trim(target_artifact_sha256)),'')),'rpc','{}'::jsonb);
  return result_id;
end
$$;

create or replace function public.create_data_subject_request(
  target_company_id uuid,target_request_type text,target_subject_kind text,target_subject_reference text,
  target_received_at timestamptz default now(),target_metadata jsonb default '{}'::jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id uuid:=gen_random_uuid(); received_value timestamptz:=coalesce(target_received_at,now());
begin
  if not public.has_company_permission(target_company_id,'personal_data_manage') then raise exception 'forbidden' using errcode='42501'; end if;
  insert into public.data_subject_requests(
    id,company_id,request_type,subject_kind,subject_reference,received_at,due_at,status,created_by,metadata
  ) values(
    result_id,target_company_id,target_request_type,target_subject_kind,trim(target_subject_reference),
    received_value,received_value+interval '1 month','received',auth.uid(),coalesce(target_metadata,'{}'::jsonb)
  );
  perform public._append_fiscal_event(target_company_id,'data_subject_request_recorded','data_subject_request',result_id,
    received_value,jsonb_build_object('request_type',target_request_type,'subject_kind',target_subject_kind,
      'due_at',received_value+interval '1 month'),'rpc','{}'::jsonb);
  return result_id;
end
$$;

create or replace function public.run_company_integrity_check(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare chain_report jsonb; anomaly_hash text; anomaly_id uuid; archive_invalid bigint; result jsonb;
  check_id uuid:=gen_random_uuid(); report_hash text;
begin
  if not public.has_company_permission(target_company_id,'compliance_view') then raise exception 'forbidden' using errcode='42501'; end if;
  chain_report:=public.verify_fiscal_event_chain(target_company_id);
  select count(*) into archive_invalid from public.fiscal_archives archive
  where archive.company_id=target_company_id
    and not coalesce((public.verify_fiscal_archive_record(archive.id)->>'valid')::boolean,false);
  result:=jsonb_build_object('event_chain',chain_report,'invalid_archives',archive_invalid,
    'status',case when coalesce((chain_report->>'valid')::boolean,false) and archive_invalid=0 then 'valid' else 'anomaly' end,
    'checked_at',clock_timestamp(),'signature_verification','not_available_without_kms');
  report_hash:=encode(extensions.digest(convert_to(result::text,'UTF8'),'sha256'),'hex');
  insert into public.compliance_integrity_checks(
    id,company_id,status,checked_at,checked_by,checked_events,invalid_archives,signature_verification,
    report,report_sha256,application_version,schema_version
  ) values(
    check_id,target_company_id,result->>'status',(result->>'checked_at')::timestamptz,auth.uid(),
    coalesce((chain_report->>'checked_events')::bigint,0),archive_invalid,'not_available_without_kms',
    result,report_hash,'0.9.0-compliance.2','202607220045'
  );
  if not coalesce((chain_report->>'valid')::boolean,false) or archive_invalid>0 then
    anomaly_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
      'chain_anomalies',chain_report->'anomalies','last_hash',chain_report->>'last_hash','invalid_archives',archive_invalid
    )::text,'UTF8'),'sha256'),'hex');
    select id into anomaly_id from public.compliance_anomalies
    where company_id=target_company_id and anomaly_type='integrity_check_failed' and detected_hash=anomaly_hash;
    if anomaly_id is null then
      anomaly_id:=gen_random_uuid();
      insert into public.compliance_anomalies(
        id,company_id,anomaly_type,severity,source,detected_hash,details,detected_by,application_version,schema_version
      ) values(
        anomaly_id,target_company_id,'integrity_check_failed','critical','run_company_integrity_check',anomaly_hash,
        result,auth.uid(),'0.9.0-compliance.2','202607220045'
      );
      perform public._append_fiscal_event(target_company_id,'compliance_anomaly_detected','compliance_anomaly',anomaly_id,
        clock_timestamp(),jsonb_build_object('type','integrity_check_failed','severity','critical','detected_hash',anomaly_hash),
        'rpc','{}'::jsonb);
    end if;
  end if;
  return result;
end
$$;

create or replace function public.evaluate_fiscal_activation(target_company_id uuid,target_mode text default 'production')
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare config public.company_fiscal_configurations%rowtype; company_data public.company_settings%rowtype;
  blockers jsonb:='[]'::jsonb; required_evidence text[]; evidence_kind text; chain_report jsonb;
  sequence_count integer; verified_profile_count integer; open_critical bigint;
begin
  if target_mode not in('test','production') then raise exception 'invalid_fiscal_mode'; end if;
  if not public.has_company_permission(target_company_id,'compliance_view') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  select * into company_data from public.company_settings where company_id=target_company_id;
  if config.company_id is null then blockers:=blockers||jsonb_build_array('Configuration fiscale absente'); end if;
  if company_data.company_id is null or nullif(trim(company_data.legal_name),'') is null then blockers:=blockers||jsonb_build_array('Raison sociale absente'); end if;
  if company_data.company_id is null or nullif(trim(company_data.siret),'') is null then blockers:=blockers||jsonb_build_array('SIRET absent'); end if;
  if company_data.company_id is null or nullif(trim(company_data.address_line1),'') is null
    or nullif(trim(company_data.postal_code),'') is null or nullif(trim(company_data.city),'') is null then
    blockers:=blockers||jsonb_build_array('Adresse légale incomplète');
  end if;
  select count(distinct document_type) into sequence_count from public.document_sequences
  where company_id=target_company_id and document_type in('invoice','credit_note');
  if sequence_count<2 then blockers:=blockers||jsonb_build_array('Séquences facture et avoir incomplètes'); end if;
  chain_report:=public.verify_fiscal_event_chain(target_company_id);
  if not coalesce((chain_report->>'valid')::boolean,false) then blockers:=blockers||jsonb_build_array('Chaîne fiscale invalide'); end if;
  select count(*) into open_critical from public.compliance_anomalies anomaly
  where anomaly.company_id=target_company_id and anomaly.severity='critical'
    and not exists(select 1 from public.compliance_anomaly_resolutions resolution where resolution.anomaly_id=anomaly.id);
  if open_critical>0 then blockers:=blockers||jsonb_build_array('Anomalie critique non résolue'); end if;
  required_evidence:=case when target_mode='production'
    then array['backup_restore_test','release_test_report','security_review','kms_key_validation']::text[]
    else array['release_test_report']::text[] end;
  foreach evidence_kind in array required_evidence loop
    if not exists(select 1 from public.company_compliance_evidence evidence
      where evidence.company_id=target_company_id and evidence.evidence_type=evidence_kind
        and evidence.status='verified' and evidence.verified_at is not null
        and (evidence.expires_at is null or evidence.expires_at>now())) then
      blockers:=blockers||jsonb_build_array('Preuve vérifiée manquante : '||evidence_kind);
    end if;
  end loop;
  if target_mode='production' and (config.signing_status<>'configured' or nullif(trim(config.kms_key_id),'') is null) then
    blockers:=blockers||jsonb_build_array('Clé KMS de signature non configurée ou non validée');
  end if;
  if target_mode='production' then
    select count(*) into verified_profile_count from public.electronic_format_profiles where validation_status='verified';
    if verified_profile_count=0 then blockers:=blockers||jsonb_build_array('Aucun profil électronique officiel vérifié'); end if;
  end if;
  return jsonb_build_object('ready',jsonb_array_length(blockers)=0,'target_mode',target_mode,'blockers',blockers,
    'evaluated_at',clock_timestamp(),'application_version','0.9.0-compliance.2','schema_version','202607220045',
    'warning','Cette évaluation technique ne constitue ni une certification ni un avis juridique.');
end
$$;

create or replace function public.activate_fiscal_engine(target_company_id uuid,target_mode text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare evaluation jsonb; new_status text;
begin
  if not public.has_company_role(target_company_id,array['owner']) then raise exception 'owner_required' using errcode='42501'; end if;
  evaluation:=public.evaluate_fiscal_activation(target_company_id,target_mode);
  if not coalesce((evaluation->>'ready')::boolean,false) then
    raise exception 'fiscal_activation_prerequisites_missing:%',evaluation->'blockers' using errcode='55000';
  end if;
  new_status:=case when target_mode='test' then 'test_active' else 'production_active' end;
  update public.company_fiscal_configurations set mode=target_mode,activation_status=new_status,
    activated_at=clock_timestamp(),activated_by=auth.uid(),application_version='0.9.0-compliance.2',
    schema_version='202607220045',updated_at=clock_timestamp()
  where company_id=target_company_id;
  perform public._append_fiscal_event(target_company_id,'fiscal_engine_activated','fiscal_configuration',target_company_id,
    clock_timestamp(),jsonb_build_object('mode',target_mode,'activation_status',new_status,
      'application_version','0.9.0-compliance.2','schema_version','202607220045'),'rpc','{}'::jsonb);
  return jsonb_build_object('mode',target_mode,'activation_status',new_status,'activated_at',clock_timestamp());
end
$$;

create or replace function public.get_company_compliance_summary(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.has_company_permission(target_company_id,'compliance_view') then raise exception 'forbidden' using errcode='42501'; end if;
  return jsonb_build_object(
    'configuration',coalesce((select to_jsonb(config)-array['kms_key_id','prerequisites']::text[]
      from public.company_fiscal_configurations config where config.company_id=target_company_id),'{}'::jsonb),
    'activation',public.evaluate_fiscal_activation(target_company_id,'production'),
    'event_head',coalesce((select to_jsonb(head) from public.fiscal_event_heads head where head.company_id=target_company_id),'{}'::jsonb),
    'last_closure',coalesce((select to_jsonb(closure) from public.fiscal_closures closure where closure.company_id=target_company_id order by closure.period_end desc limit 1),'{}'::jsonb),
    'last_archive',coalesce((select to_jsonb(archive) from public.fiscal_archives archive where archive.company_id=target_company_id order by archive.period_end desc limit 1),'{}'::jsonb),
    'last_integrity_check',coalesce((select to_jsonb(integrity_check)-array['report']::text[]
      from public.compliance_integrity_checks integrity_check where integrity_check.company_id=target_company_id
      order by integrity_check.checked_at desc limit 1),'{}'::jsonb),
    'unresolved_anomalies',coalesce((select jsonb_agg(to_jsonb(anomaly) order by anomaly.detected_at desc)
      from public.compliance_anomalies anomaly where anomaly.company_id=target_company_id
        and not exists(select 1 from public.compliance_anomaly_resolutions resolution where resolution.anomaly_id=anomaly.id)),'[]'::jsonb),
    'certifications',coalesce((select jsonb_agg(to_jsonb(certificate) order by certificate.issued_at desc)
      from public.company_software_certifications certificate where certificate.company_id=target_company_id),'[]'::jsonb),
    'open_data_subject_requests',(select count(*) from public.data_subject_requests request
      where request.company_id=target_company_id and request.status not in('fulfilled','refused','cancelled')),
    'verified_format_profiles',(select count(*) from public.electronic_format_profiles profile where profile.validation_status='verified'),
    'production_connectors',(select count(*) from public.platform_connectors connector where connector.company_id=target_company_id
      and connector.production_enabled and connector.status='active'),
    'blocked_electronic_documents',(select count(*) from public.documents document where document.company_id=target_company_id
      and document.electronic_invoice_status in('canonical_invalid','format_blocked','rejected','suspended')),
    'pending_e_reporting_records',(select count(*) from public.e_reporting_records reporting where reporting.company_id=target_company_id
      and reporting.transmission_status in('not_queued','queued','failed')),
    'generated_at',clock_timestamp()
  );
end
$$;

revoke all on function public.register_compliance_evidence(uuid,text,text,text,text,text,timestamptz,jsonb) from public,anon;
revoke all on function public.set_company_member_access(uuid,uuid,text,jsonb) from public,anon;
revoke all on function public.create_data_subject_request(uuid,text,text,text,timestamptz,jsonb) from public,anon;
revoke all on function public.run_company_integrity_check(uuid) from public,anon;
revoke all on function public.evaluate_fiscal_activation(uuid,text) from public,anon;
revoke all on function public.activate_fiscal_engine(uuid,text) from public,anon;
revoke all on function public.get_company_compliance_summary(uuid) from public,anon;
grant execute on function public.register_compliance_evidence(uuid,text,text,text,text,text,timestamptz,jsonb) to authenticated;
grant execute on function public.set_company_member_access(uuid,uuid,text,jsonb) to authenticated;
grant execute on function public.create_data_subject_request(uuid,text,text,text,timestamptz,jsonb) to authenticated;
grant execute on function public.run_company_integrity_check(uuid) to authenticated;
grant execute on function public.evaluate_fiscal_activation(uuid,text) to authenticated;
grant execute on function public.activate_fiscal_engine(uuid,text) to authenticated;
grant execute on function public.get_company_compliance_summary(uuid) to authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.2',
  alter column schema_version set default '202607220045';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.2',schema_version='202607220045',updated_at=now()
where activated_at is null and mode in('off','test');

commit;
