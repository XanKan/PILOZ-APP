begin;

-- Phase 10 - closure scheduling and missing-period detection. Automation is
-- disabled by default and archives remain blocked until the signing/storage
-- provider has been validated. No pg_cron job is created by this migration.

create table if not exists public.fiscal_automation_policies(
  company_id uuid primary key references public.companies(id) on delete restrict,
  timezone text not null default 'Europe/Paris',
  daily_closure_enabled boolean not null default false,
  monthly_closure_enabled boolean not null default false,
  annual_closure_enabled boolean not null default false,
  archive_enabled boolean not null default false,
  daily_lookback_days integer not null default 35 check(daily_lookback_days between 1 and 366),
  monthly_lookback_months integer not null default 24 check(monthly_lookback_months between 1 and 120),
  annual_lookback_years integer not null default 5 check(annual_lookback_years between 1 and 20),
  last_started_at timestamptz,
  last_completed_at timestamptz,
  last_status text check(last_status is null or last_status in('success','partial','failed')),
  configured_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fiscal_maintenance_runs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  status text not null check(status in('success','partial','failed')),
  requested_by uuid,
  source text not null check(source in('manual','scheduled','service')),
  candidate_count integer not null default 0,
  created_count integer not null default 0,
  failed_count integer not null default 0,
  details jsonb not null default '[]'::jsonb,
  application_version text not null,
  schema_version text not null,
  created_at timestamptz not null default now()
);
create index if not exists fiscal_maintenance_runs_company_time_idx
  on public.fiscal_maintenance_runs(company_id,started_at desc);

alter table public.fiscal_automation_policies enable row level security;
alter table public.fiscal_maintenance_runs enable row level security;
drop policy if exists fiscal_automation_policies_select on public.fiscal_automation_policies;
create policy fiscal_automation_policies_select on public.fiscal_automation_policies for select to authenticated
using(public.has_company_permission(company_id,'compliance_view'));
drop policy if exists fiscal_maintenance_runs_select on public.fiscal_maintenance_runs;
create policy fiscal_maintenance_runs_select on public.fiscal_maintenance_runs for select to authenticated
using(public.has_company_permission(company_id,'fiscal_read'));
revoke all on public.fiscal_automation_policies,public.fiscal_maintenance_runs from anon,authenticated;
grant select on public.fiscal_automation_policies,public.fiscal_maintenance_runs to authenticated;
drop trigger if exists fiscal_automation_policies_set_updated_at on public.fiscal_automation_policies;
create trigger fiscal_automation_policies_set_updated_at before update on public.fiscal_automation_policies
for each row execute function public.set_current_timestamp_updated_at();
drop trigger if exists fiscal_maintenance_runs_immutable on public.fiscal_maintenance_runs;
create trigger fiscal_maintenance_runs_immutable before update or delete on public.fiscal_maintenance_runs
for each row execute function public.protect_immutable_fiscal_row();

insert into public.fiscal_automation_policies(company_id)
select id from public.companies on conflict(company_id) do nothing;

create or replace function public.seed_company_fiscal_automation_policy()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.fiscal_automation_policies(company_id) values(new.id)
  on conflict(company_id) do nothing;
  return new;
end
$$;
revoke all on function public.seed_company_fiscal_automation_policy() from public,anon,authenticated;
drop trigger if exists companies_seed_fiscal_automation_policy on public.companies;
create trigger companies_seed_fiscal_automation_policy after insert on public.companies
for each row execute function public.seed_company_fiscal_automation_policy();

create or replace function public.configure_fiscal_automation(
  target_company_id uuid,
  target_timezone text default 'Europe/Paris',
  enable_daily boolean default false,
  enable_monthly boolean default false,
  enable_annual boolean default false,
  enable_archives boolean default false
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare policy_row public.fiscal_automation_policies%rowtype;
begin
  if not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if not exists(select 1 from pg_timezone_names where name=target_timezone) then
    raise exception 'invalid_timezone';
  end if;
  if enable_archives then
    raise exception 'automatic_archives_require_validated_signing_and_storage_provider'
      using hint='Conserver archive_enabled=false tant que le KMS et le stockage long terme ne sont pas validÃ©s.';
  end if;
  insert into public.fiscal_automation_policies(
    company_id,timezone,daily_closure_enabled,monthly_closure_enabled,
    annual_closure_enabled,archive_enabled,configured_by
  ) values(
    target_company_id,target_timezone,enable_daily,enable_monthly,enable_annual,false,auth.uid()
  ) on conflict(company_id) do update set
    timezone=excluded.timezone,daily_closure_enabled=excluded.daily_closure_enabled,
    monthly_closure_enabled=excluded.monthly_closure_enabled,
    annual_closure_enabled=excluded.annual_closure_enabled,archive_enabled=false,
    configured_by=auth.uid(),updated_at=clock_timestamp()
  returning * into policy_row;
  perform public._append_fiscal_event(
    target_company_id,'fiscal_automation_configured','fiscal_automation_policy',target_company_id,
    clock_timestamp(),jsonb_build_object(
      'timezone',policy_row.timezone,'daily',policy_row.daily_closure_enabled,
      'monthly',policy_row.monthly_closure_enabled,'annual',policy_row.annual_closure_enabled,
      'archives',false
    ),'rpc','{}'::jsonb
  );
  return to_jsonb(policy_row)-array['configured_by']::text[];
end
$$;

create or replace function public._fiscal_maintenance_candidates(
  target_company_id uuid,target_at timestamptz default now()
) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare policy_row public.fiscal_automation_policies%rowtype; local_now timestamp; result jsonb;
begin
  select * into policy_row from public.fiscal_automation_policies where company_id=target_company_id;
  if policy_row.company_id is null then return '[]'::jsonb; end if;
  local_now:=target_at at time zone policy_row.timezone;
  with candidates as(
    select 'daily'::text closure_type,
      ((date_trunc('day',local_now)-make_interval(days=>offset_value)) at time zone policy_row.timezone) period_start,
      ((date_trunc('day',local_now)-make_interval(days=>offset_value-1)) at time zone policy_row.timezone) period_end,
      policy_row.daily_closure_enabled enabled
    from generate_series(1,policy_row.daily_lookback_days) offset_value
    union all
    select 'monthly',
      ((date_trunc('month',local_now)-make_interval(months=>offset_value)) at time zone policy_row.timezone),
      ((date_trunc('month',local_now)-make_interval(months=>offset_value-1)) at time zone policy_row.timezone),
      policy_row.monthly_closure_enabled
    from generate_series(1,policy_row.monthly_lookback_months) offset_value
    union all
    select 'annual',
      ((date_trunc('year',local_now)-make_interval(years=>offset_value)) at time zone policy_row.timezone),
      ((date_trunc('year',local_now)-make_interval(years=>offset_value-1)) at time zone policy_row.timezone),
      policy_row.annual_closure_enabled
    from generate_series(1,policy_row.annual_lookback_years) offset_value
  ), evaluated as(
    select candidate.*,
      exists(select 1 from public.fiscal_closures closure
        where closure.company_id=target_company_id and closure.closure_type=candidate.closure_type
          and closure.period_start=candidate.period_start and closure.period_end=candidate.period_end) already_created,
      exists(select 1 from public.fiscal_events event
        where event.company_id=target_company_id and event.occurred_at>=candidate.period_start
          and event.occurred_at<candidate.period_end) has_activity
    from candidates candidate
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'closure_type',closure_type,'period_start',period_start,'period_end',period_end,
    'enabled',enabled,'already_created',already_created,'has_activity',has_activity,
    'due',enabled and not already_created and has_activity
  ) order by period_start,closure_type),'[]'::jsonb) into result from evaluated;
  return result;
end
$$;
revoke all on function public._fiscal_maintenance_candidates(uuid,timestamptz) from public,anon,authenticated;

create or replace function public.preview_fiscal_maintenance(target_company_id uuid,target_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare candidates jsonb;
begin
  if not public.has_company_permission(target_company_id,'compliance_view') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  candidates:=public._fiscal_maintenance_candidates(target_company_id,target_at);
  return jsonb_build_object(
    'company_id',target_company_id,'previewed_at',target_at,'candidates',candidates,
    'due_count',(select count(*) from jsonb_array_elements(candidates) item where (item->>'due')::boolean),
    'automatic_archives_enabled',false,
    'archive_blocker','KMS et stockage long terme validÃ©s requis avant automatisation.'
  );
end
$$;

-- Same immutable closure implementation, with one explicit service boundary:
-- calls without auth.uid are only possible through service_role/Postgres jobs,
-- because anon has no EXECUTE privilege on either public entry point.
create or replace function public.generate_fiscal_closure(
  target_company_id uuid,target_closure_type text,target_period_start timestamptz,target_period_end timestamptz
) returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  config public.company_fiscal_configurations%rowtype; closure_id uuid:=gen_random_uuid(); closure_number_value text;
  collections numeric:=0; corrections numeric:=0; refunds numeric:=0; method_breakdown jsonb:='{}'::jsonb;
  first_sequence bigint; last_sequence bigint; events_count bigint:=0; previous_hash text; cumulative jsonb;
  summary jsonb; period_digest text; closure_digest text; event_id uuid;
begin
  if target_closure_type not in('daily','monthly','annual') or target_period_start is null
    or target_period_end<=target_period_start then raise exception 'invalid_closure_period'; end if;
  if auth.uid() is not null and not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_period_end>clock_timestamp() then raise exception 'closure_period_not_finished'; end if;
  if exists(select 1 from public.fiscal_closures where company_id=target_company_id and closure_type=target_closure_type
    and tstzrange(period_start,period_end,'[)')&&tstzrange(target_period_start,target_period_end,'[)')) then
    raise exception 'closure_period_overlap';
  end if;
  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  select coalesce(sum(amount) filter(where entry_type in('payment','overpayment')),0),
    coalesce(sum(amount) filter(where entry_type in('correction','rejection','chargeback')),0),
    coalesce(sum(amount) filter(where entry_type='refund'),0)
  into collections,corrections,refunds from public.payments
  where company_id=target_company_id and status='confirmed'
    and paid_at>=target_period_start and paid_at<target_period_end;
  select coalesce(jsonb_object_agg(method,total),'{}'::jsonb) into method_breakdown from(
    select coalesce(nullif(payment_method,''),'unspecified') method,round(sum(amount),2) total
    from public.payments where company_id=target_company_id and status='confirmed'
      and paid_at>=target_period_start and paid_at<target_period_end
    group by coalesce(nullif(payment_method,''),'unspecified')
  ) methods;
  select min(sequence_number),max(sequence_number),count(*) into first_sequence,last_sequence,events_count
  from public.fiscal_events where company_id=target_company_id
    and occurred_at>=target_period_start and occurred_at<target_period_end;
  select closure_hash into previous_hash from public.fiscal_closures where company_id=target_company_id
    order by period_end desc,created_at desc limit 1;
  select jsonb_build_object(
    'collections',coalesce(sum(total_collections),0)+collections,
    'corrections',coalesce(sum(total_corrections),0)+corrections,
    'refunds',coalesce(sum(total_refunds),0)+refunds
  ) into cumulative from public.fiscal_closures where company_id=target_company_id;
  closure_number_value:=public._piloz_take_document_number(
    target_company_id,'closure_'||target_closure_type,
    extract(year from target_period_end at time zone 'UTC')::integer,false
  );
  summary:=jsonb_build_object(
    'closure_id',closure_id,'closure_type',target_closure_type,'period_start',target_period_start,
    'period_end',target_period_end,'closure_number',closure_number_value,'collections',collections,
    'corrections',corrections,'refunds',refunds,'payment_method_breakdown',method_breakdown,
    'vat_breakdown_status','not_computed_requires_validation','event_count',events_count,
    'first_event_sequence',first_sequence,'last_event_sequence',last_sequence,
    'previous_closure_hash',previous_hash
  );
  period_digest:=encode(extensions.digest(convert_to(summary::text,'UTF8'),'sha256'),'hex');
  closure_digest:=encode(extensions.digest(convert_to(concat_ws('|',previous_hash,period_digest,
    closure_number_value,coalesce(config.application_version,'0.9.0-compliance.3'),'202607220047'),'UTF8'),'sha256'),'hex');
  insert into public.fiscal_closures(
    id,company_id,closure_type,period_start,period_end,closure_number,created_by,
    total_collections,total_corrections,total_refunds,payment_method_breakdown,vat_breakdown,
    cumulative_totals,event_count,first_event_sequence,last_event_sequence,period_hash,
    previous_closure_hash,closure_hash,signature,signature_key_id,integrity_status,
    application_version,schema_version,metadata
  ) values(
    closure_id,target_company_id,target_closure_type,target_period_start,target_period_end,
    closure_number_value,auth.uid(),collections,corrections,refunds,method_breakdown,
    jsonb_build_object('status','not_computed_requires_validation'),cumulative,events_count,
    first_sequence,last_sequence,period_digest,previous_hash,closure_digest,null,null,'unsigned',
    coalesce(config.application_version,'0.9.0-compliance.3'),'202607220047',
    jsonb_build_object('signature_status','not_configured','nf525_closure_level','requires_external_validation')
  );
  event_id:=public._append_fiscal_event(
    target_company_id,target_closure_type||'_closure_created','fiscal_closure',closure_id,
    target_period_end,summary||jsonb_build_object('period_hash',period_digest,'closure_hash',closure_digest),
    case when auth.uid() is null then 'scheduled_job' else 'rpc' end,'{}'::jsonb
  );
  return closure_id;
end
$$;

create or replace function public.run_company_fiscal_maintenance(
  target_company_id uuid,target_at timestamptz default now(),target_dry_run boolean default true,
  target_source text default 'manual'
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare candidates jsonb; candidate jsonb; result_details jsonb:='[]'::jsonb; run_id uuid:=gen_random_uuid();
  started timestamptz:=clock_timestamp(); closure_id uuid; candidate_count integer:=0;
  created_count integer:=0; failed_count integer:=0; final_status text;
begin
  if auth.uid() is not null and not public.has_company_role(target_company_id,array['owner','admin']) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_source not in('manual','scheduled','service') then raise exception 'invalid_maintenance_source'; end if;
  candidates:=public._fiscal_maintenance_candidates(target_company_id,target_at);
  select count(*) into candidate_count from jsonb_array_elements(candidates) item where (item->>'due')::boolean;
  if target_dry_run then
    return jsonb_build_object('dry_run',true,'candidate_count',candidate_count,'candidates',candidates,
      'destructive_action_executed',false,'archives_created',0);
  end if;
  update public.fiscal_automation_policies set last_started_at=started where company_id=target_company_id;
  for candidate in select item from jsonb_array_elements(candidates) item where (item->>'due')::boolean loop
    begin
      closure_id:=public.generate_fiscal_closure(
        target_company_id,candidate->>'closure_type',(candidate->>'period_start')::timestamptz,
        (candidate->>'period_end')::timestamptz
      );
      created_count:=created_count+1;
      result_details:=result_details||jsonb_build_array(candidate||jsonb_build_object(
        'status','created','closure_id',closure_id));
    exception when others then
      failed_count:=failed_count+1;
      result_details:=result_details||jsonb_build_array(candidate||jsonb_build_object(
        'status','failed','error_code',sqlstate,'error_message',sqlerrm));
    end;
  end loop;
  final_status:=case when failed_count=0 then 'success' when created_count>0 then 'partial' else 'failed' end;
  insert into public.fiscal_maintenance_runs(
    id,company_id,started_at,completed_at,status,requested_by,source,candidate_count,
    created_count,failed_count,details,application_version,schema_version
  ) values(
    run_id,target_company_id,started,clock_timestamp(),final_status,auth.uid(),target_source,
    candidate_count,created_count,failed_count,result_details,'0.9.0-compliance.3','202607220047'
  );
  update public.fiscal_automation_policies set last_completed_at=clock_timestamp(),last_status=final_status
  where company_id=target_company_id;
  perform public._append_fiscal_event(
    target_company_id,'fiscal_maintenance_completed','fiscal_maintenance_run',run_id,
    clock_timestamp(),jsonb_build_object('status',final_status,'candidate_count',candidate_count,
      'created_count',created_count,'failed_count',failed_count,'archives_created',0),
    case when auth.uid() is null then 'scheduled_job' else 'rpc' end,'{}'::jsonb
  );
  return jsonb_build_object('dry_run',false,'run_id',run_id,'status',final_status,
    'candidate_count',candidate_count,'created_count',created_count,'failed_count',failed_count,
    'details',result_details,'archives_created',0,
    'archive_blocker','KMS et stockage long terme validÃ©s requis.');
end
$$;

create or replace function public.run_due_fiscal_maintenance(target_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare policy_row public.fiscal_automation_policies%rowtype; result jsonb:='[]'::jsonb;
begin
  for policy_row in select * from public.fiscal_automation_policies
    where daily_closure_enabled or monthly_closure_enabled or annual_closure_enabled loop
    begin
      result:=result||jsonb_build_array(public.run_company_fiscal_maintenance(
        policy_row.company_id,target_at,false,'scheduled'));
    exception when others then
      result:=result||jsonb_build_array(jsonb_build_object(
        'company_id',policy_row.company_id,'status','failed','error_code',sqlstate,'error_message',sqlerrm));
    end;
  end loop;
  return jsonb_build_object('executed_at',target_at,'companies',result,
    'archive_automation_enabled',false);
end
$$;

revoke all on function public.configure_fiscal_automation(uuid,text,boolean,boolean,boolean,boolean) from public,anon;
revoke all on function public.preview_fiscal_maintenance(uuid,timestamptz) from public,anon;
revoke all on function public.generate_fiscal_closure(uuid,text,timestamptz,timestamptz) from public,anon;
revoke all on function public.run_company_fiscal_maintenance(uuid,timestamptz,boolean,text) from public,anon;
revoke all on function public.run_due_fiscal_maintenance(timestamptz) from public,anon,authenticated;
grant execute on function public.configure_fiscal_automation(uuid,text,boolean,boolean,boolean,boolean) to authenticated;
grant execute on function public.preview_fiscal_maintenance(uuid,timestamptz) to authenticated;
grant execute on function public.generate_fiscal_closure(uuid,text,timestamptz,timestamptz) to authenticated,service_role;
grant execute on function public.run_company_fiscal_maintenance(uuid,timestamptz,boolean,text) to authenticated,service_role;
grant execute on function public.run_due_fiscal_maintenance(timestamptz) to service_role;

create or replace function public.run_company_integrity_check(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare chain_report jsonb; anomaly_hash text; anomaly_id uuid; archive_invalid bigint;
  over_reversed bigint; privacy_cross_company bigint; result jsonb;
  check_id uuid:=gen_random_uuid(); report_hash text;
begin
  if not public.has_company_permission(target_company_id,'compliance_view') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  chain_report:=public.verify_fiscal_event_chain(target_company_id);
  select count(*) into archive_invalid from public.fiscal_archives archive
  where archive.company_id=target_company_id
    and not coalesce((public.verify_fiscal_archive_record(archive.id)->>'valid')::boolean,false);
  select count(*) into over_reversed from(
    select original.id from public.payments original
    left join public.payments reversal on reversal.reverses_payment_id=original.id and reversal.status='confirmed'
    where original.company_id=target_company_id and original.entry_type in('payment','overpayment')
    group by original.id,original.amount having coalesce(-sum(reversal.amount),0)>original.amount+0.005
  ) invalid_reversal;
  select count(*) into privacy_cross_company from public.data_subject_request_events event
  join public.data_subject_requests request on request.id=event.request_id
  where event.company_id=target_company_id and event.company_id<>request.company_id;
  result:=jsonb_build_object(
    'event_chain',chain_report,'invalid_archives',archive_invalid,
    'over_reversed_payments',over_reversed,'cross_company_privacy_events',privacy_cross_company,
    'status',case when coalesce((chain_report->>'valid')::boolean,false) and archive_invalid=0
      and over_reversed=0 and privacy_cross_company=0 then 'valid' else 'anomaly' end,
    'checked_at',clock_timestamp(),'signature_verification','not_available_without_kms'
  );
  report_hash:=encode(extensions.digest(convert_to(result::text,'UTF8'),'sha256'),'hex');
  insert into public.compliance_integrity_checks(
    id,company_id,status,checked_at,checked_by,checked_events,invalid_archives,
    signature_verification,report,report_sha256,application_version,schema_version
  ) values(
    check_id,target_company_id,result->>'status',(result->>'checked_at')::timestamptz,auth.uid(),
    coalesce((chain_report->>'checked_events')::bigint,0),archive_invalid,'not_available_without_kms',
    result,report_hash,'0.9.0-compliance.3','202607220047'
  );
  if result->>'status'='anomaly' then
    anomaly_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
      'chain_anomalies',chain_report->'anomalies','last_hash',chain_report->>'last_hash',
      'invalid_archives',archive_invalid,'over_reversed_payments',over_reversed,
      'cross_company_privacy_events',privacy_cross_company
    )::text,'UTF8'),'sha256'),'hex');
    select id into anomaly_id from public.compliance_anomalies
    where company_id=target_company_id and anomaly_type='integrity_check_failed' and detected_hash=anomaly_hash;
    if anomaly_id is null then
      anomaly_id:=gen_random_uuid();
      insert into public.compliance_anomalies(
        id,company_id,anomaly_type,severity,source,detected_hash,details,detected_by,
        application_version,schema_version
      ) values(
        anomaly_id,target_company_id,'integrity_check_failed','critical','run_company_integrity_check',
        anomaly_hash,result,auth.uid(),'0.9.0-compliance.3','202607220047'
      );
      perform public._append_fiscal_event(
        target_company_id,'compliance_anomaly_detected','compliance_anomaly',anomaly_id,
        clock_timestamp(),jsonb_build_object('type','integrity_check_failed','severity','critical',
          'detected_hash',anomaly_hash),'rpc','{}'::jsonb
      );
    end if;
  end if;
  return result;
end
$$;

create or replace function public.evaluate_fiscal_activation(target_company_id uuid,target_mode text default 'production')
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare config public.company_fiscal_configurations%rowtype; company_data public.company_settings%rowtype;
  automation public.fiscal_automation_policies%rowtype; blockers jsonb:='[]'::jsonb;
  required_evidence text[]; evidence_kind text; chain_report jsonb;
  sequence_count integer; verified_profile_count integer; open_critical bigint;
begin
  if target_mode not in('test','production') then raise exception 'invalid_fiscal_mode'; end if;
  if not public.has_company_permission(target_company_id,'compliance_view') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select * into config from public.company_fiscal_configurations where company_id=target_company_id;
  select * into company_data from public.company_settings where company_id=target_company_id;
  select * into automation from public.fiscal_automation_policies where company_id=target_company_id;
  if config.company_id is null then blockers:=blockers||jsonb_build_array('Configuration fiscale absente'); end if;
  if company_data.company_id is null or nullif(trim(company_data.legal_name),'') is null then
    blockers:=blockers||jsonb_build_array('Raison sociale absente'); end if;
  if company_data.company_id is null or nullif(trim(company_data.siret),'') is null then
    blockers:=blockers||jsonb_build_array('SIRET absent'); end if;
  if company_data.company_id is null or nullif(trim(company_data.address_line1),'') is null
    or nullif(trim(company_data.postal_code),'') is null or nullif(trim(company_data.city),'') is null then
    blockers:=blockers||jsonb_build_array('Adresse lÃ©gale incomplÃ¨te');
  end if;
  select count(distinct document_type) into sequence_count from public.document_sequences
  where company_id=target_company_id and document_type in('invoice','credit_note');
  if sequence_count<2 then blockers:=blockers||jsonb_build_array('SÃ©quences facture et avoir incomplÃ¨tes'); end if;
  chain_report:=public.verify_fiscal_event_chain(target_company_id);
  if not coalesce((chain_report->>'valid')::boolean,false) then
    blockers:=blockers||jsonb_build_array('ChaÃ®ne fiscale invalide'); end if;
  select count(*) into open_critical from public.compliance_anomalies anomaly
  where anomaly.company_id=target_company_id and anomaly.severity='critical'
    and not exists(select 1 from public.compliance_anomaly_resolutions resolution where resolution.anomaly_id=anomaly.id);
  if open_critical>0 then blockers:=blockers||jsonb_build_array('Anomalie critique non rÃ©solue'); end if;
  required_evidence:=case when target_mode='production'
    then array['backup_restore_test','release_test_report','security_review','kms_key_validation']::text[]
    else array['release_test_report']::text[] end;
  foreach evidence_kind in array required_evidence loop
    if not exists(select 1 from public.company_compliance_evidence evidence
      where evidence.company_id=target_company_id and evidence.evidence_type=evidence_kind
        and evidence.status='verified' and evidence.verified_at is not null
        and (evidence.expires_at is null or evidence.expires_at>now())) then
      blockers:=blockers||jsonb_build_array('Preuve vÃ©rifiÃ©e manquante : '||evidence_kind);
    end if;
  end loop;
  if target_mode='production' and (config.signing_status<>'configured' or nullif(trim(config.kms_key_id),'') is null) then
    blockers:=blockers||jsonb_build_array('ClÃ© KMS de signature non configurÃ©e ou non validÃ©e');
  end if;
  if target_mode='production' and not coalesce(automation.daily_closure_enabled,false) then
    blockers:=blockers||jsonb_build_array('ClÃ´ture journaliÃ¨re automatique non configurÃ©e');
  end if;
  if target_mode='production' and not coalesce(automation.monthly_closure_enabled,false) then
    blockers:=blockers||jsonb_build_array('ClÃ´ture mensuelle automatique non configurÃ©e');
  end if;
  if target_mode='production' then
    select count(*) into verified_profile_count from public.electronic_format_profiles where validation_status='verified';
    if verified_profile_count=0 then blockers:=blockers||jsonb_build_array('Aucun profil Ã©lectronique officiel vÃ©rifiÃ©'); end if;
  end if;
  return jsonb_build_object(
    'ready',jsonb_array_length(blockers)=0,'target_mode',target_mode,'blockers',blockers,
    'evaluated_at',clock_timestamp(),'application_version','0.9.0-compliance.3',
    'schema_version','202607220047',
    'warning','Cette Ã©valuation technique ne constitue ni une certification ni un avis juridique.'
  );
end
$$;

create or replace function public.activate_fiscal_engine(target_company_id uuid,target_mode text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare evaluation jsonb; new_status text;
begin
  if not public.has_company_role(target_company_id,array['owner']) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  evaluation:=public.evaluate_fiscal_activation(target_company_id,target_mode);
  if not coalesce((evaluation->>'ready')::boolean,false) then
    raise exception 'fiscal_activation_prerequisites_missing:%',evaluation->'blockers' using errcode='55000';
  end if;
  new_status:=case when target_mode='test' then 'test_active' else 'production_active' end;
  update public.company_fiscal_configurations set
    mode=target_mode,activation_status=new_status,activated_at=clock_timestamp(),activated_by=auth.uid(),
    application_version='0.9.0-compliance.3',schema_version='202607220047',updated_at=clock_timestamp()
  where company_id=target_company_id;
  perform public._append_fiscal_event(
    target_company_id,'fiscal_engine_activated','fiscal_configuration',target_company_id,
    clock_timestamp(),jsonb_build_object('mode',target_mode,'activation_status',new_status,
      'application_version','0.9.0-compliance.3','schema_version','202607220047'),'rpc','{}'::jsonb
  );
  return jsonb_build_object('mode',target_mode,'activation_status',new_status,'activated_at',clock_timestamp());
end
$$;

revoke all on function public.run_company_integrity_check(uuid) from public,anon;
revoke all on function public.evaluate_fiscal_activation(uuid,text) from public,anon;
revoke all on function public.activate_fiscal_engine(uuid,text) from public,anon;
grant execute on function public.run_company_integrity_check(uuid) to authenticated;
grant execute on function public.evaluate_fiscal_activation(uuid,text) to authenticated;
grant execute on function public.activate_fiscal_engine(uuid,text) to authenticated;

alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.3',
  alter column schema_version set default '202607220047';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.3',schema_version='202607220047',updated_at=now()
where activated_at is null and mode in('off','test');

commit;
