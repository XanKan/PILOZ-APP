begin;

-- Retour en arrière sur un point du modèle précédent : un devis ne doit
-- JAMAIS être verrouillé pour édition tant qu'aucune facture n'en découle.
-- Le statut (en attente/accepté/refusé) reste géré comme avant, mais le
-- contenu (client, lignes, montants...) redevient modifiable à volonté via
-- un simple enregistrement — plus de notion de "finaliser" ni de nouvelle
-- version pour corriger un devis. Seule la conversion en facture verrouille
-- définitivement le devis (contenu + statut).
--
-- Le pipeline de PDF final exige normalement finalized_at (immutabilité
-- légale des factures) : on l'assouplit spécifiquement pour les devis, dont
-- l'instantané est régénéré à chaque enregistrement plutôt que figé une fois
-- pour toutes.

-- ---------------------------------------------------------------------------
-- 1. save_document_draft : statut initial "en attente" pour un devis, et
--    modification libre tant qu'aucune facture active n'en découle.
-- ---------------------------------------------------------------------------
create or replace function public.save_document_draft(
  target_document_id uuid,target_document jsonb,target_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc public.documents%rowtype; target_company_id uuid; target_type text; line_data jsonb;
  saved_id uuid; line_position integer:=0; has_downstream_invoice boolean;
begin
  if target_document is null or jsonb_typeof(coalesce(target_lines,'[]'::jsonb))<>'array' then
    raise exception 'invalid_document_payload';
  end if;
  if target_document_id is null then
    target_company_id:=nullif(target_document->>'company_id','')::uuid;
    target_type:=coalesce(nullif(target_document->>'document_type',''),'quote');
    if not public.is_company_member(target_company_id) then raise exception 'forbidden' using errcode='42501'; end if;
    if target_type not in('quote','invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice') then raise exception 'invalid_document_type'; end if;
    insert into public.documents(
      company_id,document_type,version,client_id,status,issue_date,due_date,validity_date,subject,client_reference,
      currency,language,payment_terms,payment_method,internal_notes,public_notes,discount_rate,
      source_document_id,root_document_id,version_reason,sale_type,opportunity_id,assigned_user_id,
      template_id,deposit_rate,pipeline_stage,metadata,created_by
    ) values(
      target_company_id,target_type,coalesce(nullif(target_document->>'version','')::integer,1),
      nullif(target_document->>'client_id','')::uuid,case when target_type='quote' then 'pending' else 'draft' end,
      coalesce(nullif(target_document->>'issue_date','')::date,current_date),
      nullif(target_document->>'due_date','')::date,nullif(target_document->>'validity_date','')::date,
      nullif(target_document->>'subject',''),nullif(target_document->>'client_reference',''),
      coalesce(nullif(target_document->>'currency',''),'EUR'),
      coalesce(nullif(target_document->>'language',''),'fr'),nullif(target_document->>'payment_terms',''),
      nullif(target_document->>'payment_method',''),nullif(target_document->>'internal_notes',''),
      nullif(target_document->>'public_notes',''),coalesce(nullif(target_document->>'discount_rate','')::numeric,0),
      nullif(target_document->>'source_document_id','')::uuid,nullif(target_document->>'root_document_id','')::uuid,
      nullif(target_document->>'version_reason',''),nullif(target_document->>'sale_type',''),
      nullif(target_document->>'opportunity_id','')::uuid,nullif(target_document->>'assigned_user_id','')::uuid,
      nullif(target_document->>'template_id','')::uuid,coalesce(nullif(target_document->>'deposit_rate','')::numeric,0),
      coalesce(nullif(target_document->>'pipeline_stage',''),'draft'),
      case when nullif(target_document->>'pipeline_stage','') is null then coalesce(target_document->'metadata','{}'::jsonb)
        else jsonb_set(coalesce(target_document->'metadata','{}'::jsonb),'{pipeline_stage}',to_jsonb(target_document->>'pipeline_stage'),true) end,
      auth.uid()
    ) returning id into saved_id;
  else
    select * into doc from public.documents where id=target_document_id for update;
    if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
    if doc.document_type='quote' then
      select exists(
        select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
        where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
          and target.status not in('cancelled','archived')
      ) into has_downstream_invoice;
      if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;
    elsif doc.status<>'draft' or doc.validated_at is not null or doc.finalized_at is not null then
      raise exception 'document_is_locked';
    end if;
    target_company_id:=doc.company_id; target_type:=doc.document_type; saved_id:=doc.id;
    if nullif(target_document->>'document_type','') is not null and target_document->>'document_type'<>doc.document_type then
      raise exception 'document_type_is_immutable';
    end if;
    update public.documents set
      version=coalesce(nullif(target_document->>'version','')::integer,version),
      client_id=nullif(target_document->>'client_id','')::uuid,
      issue_date=coalesce(nullif(target_document->>'issue_date','')::date,issue_date),
      due_date=nullif(target_document->>'due_date','')::date,
      validity_date=nullif(target_document->>'validity_date','')::date,
      subject=nullif(target_document->>'subject',''),client_reference=nullif(target_document->>'client_reference',''),
      currency=coalesce(nullif(target_document->>'currency',''),currency),
      language=coalesce(nullif(target_document->>'language',''),language),payment_terms=nullif(target_document->>'payment_terms',''),
      payment_method=nullif(target_document->>'payment_method',''),internal_notes=nullif(target_document->>'internal_notes',''),
      public_notes=nullif(target_document->>'public_notes',''),discount_rate=coalesce(nullif(target_document->>'discount_rate','')::numeric,0),
      source_document_id=nullif(target_document->>'source_document_id','')::uuid,
      root_document_id=nullif(target_document->>'root_document_id','')::uuid,version_reason=nullif(target_document->>'version_reason',''),
      sale_type=nullif(target_document->>'sale_type',''),opportunity_id=nullif(target_document->>'opportunity_id','')::uuid,
      assigned_user_id=nullif(target_document->>'assigned_user_id','')::uuid,template_id=nullif(target_document->>'template_id','')::uuid,
      deposit_rate=coalesce(nullif(target_document->>'deposit_rate','')::numeric,0),
      pipeline_stage=coalesce(nullif(target_document->>'pipeline_stage',''),pipeline_stage),
      metadata=case when nullif(target_document->>'pipeline_stage','') is null then coalesce(target_document->'metadata','{}'::jsonb)
        else jsonb_set(coalesce(target_document->'metadata','{}'::jsonb),'{pipeline_stage}',to_jsonb(target_document->>'pipeline_stage'),true) end,
      updated_at=now()
    where id=saved_id;
    delete from public.document_lines where document_id=saved_id;
  end if;

  for line_data in select value from jsonb_array_elements(coalesce(target_lines,'[]'::jsonb)) loop
    line_position:=line_position+1;
    insert into public.document_lines(
      id,company_id,document_id,position,line_type,section_id,item_id,reference,name,description,
      quantity,unit,unit_cost_snapshot,unit_price,discount_rate,tax_rate,optional,
      source_line_id,cumulative_progress_percent,line_metadata,created_by
    ) values(
      coalesce(nullif(line_data->>'id','')::uuid,gen_random_uuid()),target_company_id,saved_id,
      coalesce(nullif(line_data->>'position','')::integer,line_position),coalesce(nullif(line_data->>'line_type',''),'item'),
      nullif(line_data->>'section_id','')::uuid,nullif(line_data->>'item_id','')::uuid,
      nullif(line_data->>'reference',''),nullif(line_data->>'name',''),nullif(line_data->>'description',''),
      coalesce(nullif(line_data->>'quantity','')::numeric,1),nullif(line_data->>'unit',''),
      coalesce(nullif(line_data->>'unit_cost_snapshot','')::numeric,0),coalesce(nullif(line_data->>'unit_price','')::numeric,0),
      coalesce(nullif(line_data->>'discount_rate','')::numeric,0),coalesce(nullif(line_data->>'tax_rate','')::numeric,0),
      coalesce((line_data->>'optional')::boolean,false),nullif(line_data->>'source_line_id','')::uuid,
      nullif(line_data->>'cumulative_progress_percent','')::numeric,coalesce(line_data->'line_metadata','{}'::jsonb),auth.uid()
    );
  end loop;
  if target_type='quote' then
    perform public._piloz_refresh_quote_snapshot(saved_id);
  end if;
  select * into doc from public.documents where id=saved_id;
  return jsonb_build_object('id',doc.id,'number',doc.number,'status',doc.status,'updated_at',doc.updated_at);
end
$$;

-- ---------------------------------------------------------------------------
-- 2. finalize_document redevient réservé aux factures (et assimilées) : un
--    devis ne passe plus jamais par ce chemin de verrouillage.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_document(target_document_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; result_snapshot_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    raise exception 'document_type_cannot_be_finalized';
  end if;
  if doc.finalized_at is not null then
    return jsonb_build_object('id',doc.id,'number',doc.number,
      'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',doc.snapshot_id,'pdf_status',doc.pdf_status);
  end if;
  if doc.status not in('draft','to_finalize') or doc.validated_at is not null then raise exception 'invalid_document_state'; end if;
  if doc.number is null then
    update public.documents set number=public._piloz_take_document_number(
      doc.company_id,doc.document_type,extract(year from coalesce(doc.issue_date,current_date))::integer,false
    ),updated_at=now() where id=doc.id returning * into doc;
  end if;
  if not public.is_company_onboarded(doc.company_id) then raise exception 'company_onboarding_required' using errcode='42501'; end if;
  if doc.client_id is null or not exists(select 1 from public.clients where id=doc.client_id and company_id=doc.company_id and active) then
    raise exception 'document_client_required';
  end if;
  if not exists(select 1 from public.document_lines where document_id=doc.id and line_type in('item','free_item','discount')
    and not optional and nullif(trim(coalesce(name,'')),'') is not null and quantity>0) then
    raise exception 'document_lines_required';
  end if;
  if doc.total_excl_tax<=0 or doc.total_incl_tax<=0 then raise exception 'document_total_must_be_positive'; end if;
  if doc.due_date is null then
    update public.documents set due_date=public.compute_document_due_date(doc.company_id,doc.payment_terms,doc.issue_date)
    where id=doc.id returning * into doc;
  end if;
  update public.documents set
    status='finalized',validated_at=now(),finalized_at=now(),
    finalized_by=auth.uid(),locked_at=now(),pdf_status='pending',updated_at=now()
  where id=doc.id returning * into doc;
  result_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set snapshot_id=result_snapshot_id,updated_at=now() where id=doc.id returning * into doc;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,result_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by))
  on conflict(snapshot_id) do nothing;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.finalized','document',doc.id,
    jsonb_build_object('number',doc.number,'document_type',doc.document_type,'snapshot_id',result_snapshot_id),auth.uid());
  return jsonb_build_object('id',doc.id,'number',doc.number,
    'status',doc.status,'finalized_at',doc.finalized_at,'snapshot_id',result_snapshot_id,'pdf_status',doc.pdf_status);
end
$$;

-- ---------------------------------------------------------------------------
-- 3. transition_document_status : un devis n'a plus besoin d'être finalisé
--    pour changer de statut (il ne l'est jamais) ; le verrouillage par
--    facture reste inchangé.
-- ---------------------------------------------------------------------------
create or replace function public.transition_document_status(target_document_id uuid,target_status text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; allowed boolean:=false; has_downstream_invoice boolean;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then raise exception 'document_not_found' using errcode='P0002'; end if;
  if target_status=doc.status then return jsonb_build_object('id',doc.id,'status',doc.status); end if;
  if doc.document_type='quote' then
    select exists(
      select 1 from public.document_links link join public.documents target on target.id=link.target_document_id
      where link.source_document_id=doc.id and link.link_type in('invoice','deposit','progress','balance')
        and target.status not in('cancelled','archived')
    ) into has_downstream_invoice;
    if has_downstream_invoice then raise exception 'quote_locked_by_invoice'; end if;
    allowed:=target_status in('accepted','rejected','archived');
  elsif doc.finalized_at is null then
    allowed:=doc.status='draft' and target_status in('to_finalize','cancelled','archived');
  elsif doc.document_type in('invoice','deposit_invoice','balance_invoice','credit_note') then
    allowed:=target_status in('finalized','sent','overdue','archived');
  end if;
  if not allowed then raise exception 'invalid_document_status_transition'; end if;
  update public.documents set status=target_status,
    sent_at=case when target_status='sent' then coalesce(sent_at,now()) else sent_at end,
    accepted_at=case when target_status='accepted' then coalesce(accepted_at,now()) else accepted_at end,
    rejected_at=case when target_status='rejected' then coalesce(rejected_at,now()) else rejected_at end,
    expired_at=case when target_status='expired' then coalesce(expired_at,now()) else expired_at end,
    archived_at=case when target_status='archived' then coalesce(archived_at,now()) else archived_at end,
    updated_at=now() where id=doc.id returning * into doc;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(doc.company_id,auth.uid(),'document.status_changed','document',doc.id,
    jsonb_build_object('status',target_status),auth.uid());
  return jsonb_build_object('id',doc.id,'status',doc.status,'sent_at',doc.sent_at,
    'accepted_at',doc.accepted_at,'rejected_at',doc.rejected_at,'expired_at',doc.expired_at);
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Instantané et PDF : un devis n'a plus besoin d'être "finalisé" pour
--    obtenir un instantané ou un PDF final ; il est régénéré à chaque
--    enregistrement pour refléter le contenu le plus récent. Les factures
--    (et assimilées) gardent l'exigence stricte de finalized_at.
-- ---------------------------------------------------------------------------
create or replace function public._piloz_refresh_quote_snapshot(target_document_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare doc public.documents%rowtype; new_snapshot_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or doc.document_type<>'quote' then return; end if;
  new_snapshot_id:=public._piloz_create_document_snapshot(doc.id);
  update public.documents set
    snapshot_id=new_snapshot_id,pdf_status='pending',final_pdf_path=null,final_pdf_sha256=null,updated_at=now()
  where id=doc.id;
  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,new_snapshot_id,'pending',coalesce(auth.uid(),doc.created_by))
  on conflict(snapshot_id) do nothing;
end
$$;
revoke all on function public._piloz_refresh_quote_snapshot(uuid) from public,anon,authenticated;

create or replace function public._piloz_create_document_snapshot(target_document_id uuid)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  doc public.documents%rowtype; issuer jsonb; document_settings jsonb; customer jsonb; company_logo jsonb;
  public_lines jsonb; internal_lines jsonb; template_payload jsonb; logo_settings jsonb; logo_variant text;
  footer_row jsonb; footer_id_value uuid;
  public_snapshot jsonb; internal_snapshot jsonb; snapshot_hash text;
  next_version integer; result_id uuid;
begin
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or (doc.finalized_at is null and doc.document_type<>'quote') then raise exception 'document_not_finalized'; end if;
  select to_jsonb(s) into issuer from public.company_settings s where s.company_id=doc.company_id;
  select to_jsonb(s) into document_settings from public.company_document_settings s where s.company_id=doc.company_id;
  select to_jsonb(c) into customer from public.clients c where c.id=doc.client_id and c.company_id=doc.company_id;
  select jsonb_build_object('template',to_jsonb(t),'version',to_jsonb(tv)) into template_payload
  from public.document_templates t
  left join public.document_template_versions tv on tv.template_id=t.id and tv.version=t.current_version
  where t.id=doc.template_id and t.company_id=doc.company_id;
  footer_id_value:=nullif(template_payload->'version'->>'footer_id','')::uuid;
  if footer_id_value is not null then
    select to_jsonb(f) into footer_row from public.document_footers f
    where f.id=footer_id_value and f.company_id=doc.company_id;
    if footer_row is not null then
      template_payload:=jsonb_set(template_payload,'{footer}',footer_row,true);
    end if;
  end if;
  logo_settings:=coalesce(template_payload->'version'->'logo_settings','{}'::jsonb);
  logo_variant:=case when coalesce((logo_settings->>'use_alternate')::boolean,false) then 'dark' else 'light' end;
  if coalesce((logo_settings->>'show')::boolean,true) then
    select jsonb_build_object(
      'storage_path',logo.storage_path,'mime_type',logo.mime_type,'size_bytes',logo.size_bytes,
      'width',logo.width,'height',logo.height,'variant',logo.variant
    ) into company_logo
    from public.company_logos logo
    where logo.company_id=doc.company_id and logo.variant=logo_variant and logo.is_active
    order by logo.created_at desc limit 1;
    if company_logo is null and logo_variant='dark' then
      select jsonb_build_object(
        'storage_path',logo.storage_path,'mime_type',logo.mime_type,'size_bytes',logo.size_bytes,
        'width',logo.width,'height',logo.height,'variant',logo.variant
      ) into company_logo
      from public.company_logos logo
      where logo.company_id=doc.company_id and logo.variant='light' and logo.is_active
      order by logo.created_at desc limit 1;
    end if;
  end if;
  select coalesce(jsonb_agg(
    to_jsonb(l)-array['unit_cost_snapshot','line_metadata','created_by','created_at','updated_at']::text[] order by l.position
  ),'[]'::jsonb),coalesce(jsonb_agg(to_jsonb(l) order by l.position),'[]'::jsonb)
  into public_lines,internal_lines from public.document_lines l where l.document_id=doc.id;

  public_snapshot:=jsonb_build_object(
    'schema_version',2,'captured_at',now(),
    'document',to_jsonb(doc)-array['total_cost','internal_notes','final_pdf_path','final_pdf_sha256']::text[],
    'lines',public_lines,'issuer',coalesce(issuer,'{}'::jsonb),
    'document_settings',coalesce(document_settings,'{}'::jsonb)-'mandate_reference',
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(company_logo,'{}'::jsonb),
    'template',coalesce(template_payload,'{}'::jsonb)
  );
  internal_snapshot:=jsonb_build_object(
    'schema_version',2,'captured_at',now(),'document',to_jsonb(doc),'lines',internal_lines,
    'issuer',coalesce(issuer,'{}'::jsonb),'document_settings',coalesce(document_settings,'{}'::jsonb),
    'client',coalesce(customer,'{}'::jsonb),'logo',coalesce(company_logo,'{}'::jsonb),
    'template',coalesce(template_payload,'{}'::jsonb)
  );
  snapshot_hash:=encode(extensions.digest(convert_to(public_snapshot::text,'UTF8'),'sha256'),'hex');
  select coalesce(max(snapshot_version),0)+1 into next_version
  from public.document_snapshots where document_id=doc.id;
  insert into public.document_snapshots(
    company_id,document_id,snapshot_version,snapshot_kind,public_payload,internal_payload,
    payload_hash,pdf_status,created_by
  ) values(
    doc.company_id,doc.id,next_version,'finalization',public_snapshot,internal_snapshot,
    snapshot_hash,'pending',coalesce(auth.uid(),doc.created_by)
  ) returning id into result_id;
  return result_id;
end
$$;
revoke all on function public._piloz_create_document_snapshot(uuid) from public,anon,authenticated,service_role;

create or replace function public.claim_document_pdf_job(
  target_document_id uuid,target_lease_seconds integer default 300
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  actor_id uuid:=auth.uid(); doc public.documents%rowtype; snapshot public.document_snapshots%rowtype;
  job public.document_pdf_jobs%rowtype; new_token uuid:=gen_random_uuid();
  lease_seconds integer:=least(900,greatest(60,coalesce(target_lease_seconds,300)));
  active_until timestamptz;
begin
  if actor_id is null then raise exception 'authentication_required' using errcode='28000'; end if;
  select * into doc from public.documents where id=target_document_id for update;
  if doc.id is null or not public.is_company_member(doc.company_id) then
    raise exception 'document_not_found' using errcode='P0002';
  end if;
  if (doc.finalized_at is null and doc.document_type<>'quote') or doc.snapshot_id is null then raise exception 'document_not_finalized' using errcode='55000'; end if;
  select * into snapshot from public.document_snapshots
  where id=doc.snapshot_id and company_id=doc.company_id and document_id=doc.id for update;
  if snapshot.id is null then raise exception 'document_snapshot_mismatch' using errcode='55000'; end if;

  insert into public.document_pdf_jobs(company_id,document_id,snapshot_id,status,created_by)
  values(doc.company_id,doc.id,snapshot.id,'pending',actor_id) on conflict(snapshot_id) do nothing;
  select * into job from public.document_pdf_jobs
  where snapshot_id=snapshot.id and company_id=doc.company_id and document_id=doc.id for update;
  if job.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;

  if job.status='completed' then
    if doc.pdf_status='ready' and snapshot.pdf_status='ready' and doc.final_pdf_path is not null
       and doc.final_pdf_path=snapshot.pdf_storage_path then
      return jsonb_build_object('claimed',false,'ready',true,'status','completed',
        'job_id',job.id,'snapshot_id',snapshot.id,'path',snapshot.pdf_storage_path,'sha256',snapshot.pdf_sha256);
    end if;
    raise exception 'pdf_job_state_inconsistent' using errcode='55000';
  end if;

  active_until:=coalesce(job.lease_expires_at,job.started_at+make_interval(secs=>lease_seconds),'-infinity'::timestamptz);
  if job.status='processing' and active_until>now() then
    return jsonb_build_object('claimed',false,'ready',false,'status','processing',
      'job_id',job.id,'snapshot_id',snapshot.id,'retry_at',active_until);
  end if;
  if job.status in('pending','failed') and job.available_at>now() then
    return jsonb_build_object('claimed',false,'ready',false,'status',job.status,
      'job_id',job.id,'snapshot_id',snapshot.id,'retry_at',job.available_at);
  end if;

  update public.document_pdf_jobs set status='processing',attempts=attempts+1,
    last_error_code=null,started_at=now(),completed_at=null,available_at=now(),
    claim_token=new_token,claimed_by=actor_id,
    lease_expires_at=now()+make_interval(secs=>lease_seconds),updated_at=now()
  where id=job.id returning * into job;
  update public.document_snapshots set pdf_status='pending',pdf_storage_path=null,
    pdf_sha256=null,pdf_generated_at=null where id=snapshot.id;
  update public.documents set pdf_status='pending',final_pdf_path=null,
    final_pdf_sha256=null,final_pdf_generated_at=null,updated_at=now() where id=doc.id;

  return jsonb_build_object('claimed',true,'ready',false,'status','processing',
    'job_id',job.id,'claim_token',new_token,'snapshot_id',snapshot.id,
    'document_id',doc.id,'company_id',doc.company_id,'lease_expires_at',job.lease_expires_at,
    'payload_hash',snapshot.payload_hash,'public_payload',snapshot.public_payload);
end
$$;

create or replace function public.complete_document_pdf_job(
  target_job_id uuid,target_claim_token uuid,target_storage_path text,target_sha256 text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  job public.document_pdf_jobs%rowtype; doc public.documents%rowtype;
  snapshot public.document_snapshots%rowtype; expected_path text;
  normalized_hash text:=lower(trim(coalesce(target_sha256,'')));
begin
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if job.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  select * into doc from public.documents
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id
    and (finalized_at is not null or document_type='quote') for update;
  select * into snapshot from public.document_snapshots
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id for update;
  if doc.id is null or snapshot.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;
  expected_path:=job.company_id::text||'/documents/'||job.document_id::text||'/'||job.snapshot_id::text||'.pdf';
  if trim(coalesce(target_storage_path,''))<>expected_path then raise exception 'invalid_pdf_storage_path' using errcode='22023'; end if;
  if normalized_hash!~'^[0-9a-f]{64}$' then raise exception 'invalid_pdf_sha256' using errcode='22023'; end if;

  if job.status='completed' then
    if snapshot.pdf_storage_path=expected_path and snapshot.pdf_sha256=normalized_hash
       and doc.final_pdf_path=expected_path and doc.final_pdf_sha256=normalized_hash then
      return jsonb_build_object('completed',true,'idempotent',true,'job_id',job.id,
        'snapshot_id',snapshot.id,'path',expected_path,'sha256',normalized_hash);
    end if;
    raise exception 'pdf_completion_conflict' using errcode='55000';
  end if;
  if job.status<>'processing' or job.claim_token is distinct from target_claim_token or job.claimed_by is null then
    raise exception 'invalid_pdf_job_claim' using errcode='42501';
  end if;
  if not exists(select 1 from storage.objects where bucket_id='company-files' and name=expected_path) then
    raise exception 'pdf_storage_object_missing' using errcode='P0002';
  end if;

  update public.document_snapshots set pdf_storage_path=expected_path,pdf_sha256=normalized_hash,
    pdf_status='ready',pdf_generated_at=now()
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id;
  if not found then raise exception 'pdf_snapshot_update_failed' using errcode='55000'; end if;
  update public.documents set final_pdf_path=expected_path,final_pdf_sha256=normalized_hash,
    final_pdf_generated_at=now(),pdf_status='ready',updated_at=now()
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id;
  if not found then raise exception 'pdf_document_update_failed' using errcode='55000'; end if;
  update public.document_pdf_jobs set status='completed',last_error_code=null,completed_at=now(),
    available_at=now(),claim_token=null,lease_expires_at=null,updated_at=now()
  where id=job.id and status='processing' and claim_token=target_claim_token;
  if not found then raise exception 'pdf_job_completion_race' using errcode='40001'; end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(job.company_id,job.claimed_by,'document.pdf.generated','document',job.document_id,
    jsonb_build_object('snapshot_id',snapshot.id,'sha256',normalized_hash),job.claimed_by);
  return jsonb_build_object('completed',true,'idempotent',false,'job_id',job.id,
    'snapshot_id',snapshot.id,'document_id',doc.id,'path',expected_path,'sha256',normalized_hash);
end
$$;

create or replace function public.fail_document_pdf_job(
  target_job_id uuid,target_claim_token uuid,target_error_code text,target_retry_after_seconds integer default 60
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  job public.document_pdf_jobs%rowtype; doc public.documents%rowtype; snapshot public.document_snapshots%rowtype;
  retry_seconds integer:=least(3600,greatest(30,coalesce(target_retry_after_seconds,60)));
  retry_at timestamptz;
  safe_error text:=left(regexp_replace(lower(coalesce(nullif(trim(target_error_code),''),'pdf_generation_failed')),
    '[^a-z0-9_.:-]+','_','g'),120);
begin
  select * into job from public.document_pdf_jobs where id=target_job_id for update;
  if job.id is null then raise exception 'pdf_job_not_found' using errcode='P0002'; end if;
  if job.status='failed' and job.claim_token is null then
    return jsonb_build_object('failed',true,'idempotent',true,'job_id',job.id,
      'attempts',job.attempts,'retry_at',job.available_at);
  end if;
  if job.status<>'processing' or job.claim_token is distinct from target_claim_token or job.claimed_by is null then
    raise exception 'invalid_pdf_job_claim' using errcode='42501';
  end if;
  select * into doc from public.documents
  where id=job.document_id and company_id=job.company_id and snapshot_id=job.snapshot_id
    and (finalized_at is not null or document_type='quote') for update;
  select * into snapshot from public.document_snapshots
  where id=job.snapshot_id and company_id=job.company_id and document_id=job.document_id for update;
  if doc.id is null or snapshot.id is null then raise exception 'pdf_job_snapshot_mismatch' using errcode='55000'; end if;
  retry_at:=now()+make_interval(secs=>retry_seconds);
  update public.document_snapshots set pdf_status='error',pdf_storage_path=null,
    pdf_sha256=null,pdf_generated_at=null where id=job.snapshot_id and company_id=job.company_id;
  update public.documents set pdf_status='error',final_pdf_path=null,final_pdf_sha256=null,
    final_pdf_generated_at=null,updated_at=now() where id=job.document_id and company_id=job.company_id;
  update public.document_pdf_jobs set status='failed',last_error_code=safe_error,
    available_at=retry_at,completed_at=now(),claim_token=null,lease_expires_at=null,updated_at=now()
  where id=job.id and status='processing' and claim_token=target_claim_token;
  if not found then raise exception 'pdf_job_failure_race' using errcode='40001'; end if;
  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,new_data,created_by)
  values(job.company_id,job.claimed_by,'document.pdf.failed','document',job.document_id,
    jsonb_build_object('snapshot_id',snapshot.id,'error_code',safe_error,'attempt',job.attempts),job.claimed_by);
  return jsonb_build_object('failed',true,'idempotent',false,'job_id',job.id,
    'attempts',job.attempts,'error_code',safe_error,'retry_at',retry_at);
end
$$;

commit;
