begin;

-- Une piece est comptabilisable uniquement lorsqu'elle porte un numero fiscal
-- definitif et qu'elle a quitte le cycle brouillon. Le test couvre aussi les
-- factures historiques validees avant l'introduction de finalized_at.
create or replace function public._piloz_accounting_document_is_final(target_document_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1
    from public.documents document
    where document.id=target_document_id
      and document.document_type in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice')
      and nullif(trim(coalesce(document.number,'')),'') is not null
      and document.number!~*'^(BROUILLON|BR)-'
      and document.status not in('draft','to_finalize','cancelled','archived')
      and (
        document.finalized_at is not null
        or document.validated_at is not null
        or document.status in('finalized','validated','sent','pending','partially_paid','paid','overdue')
      )
  )
$$;

-- Le moteur initial ignorait les anciennes factures dont finalized_at etait
-- vide, meme lorsqu'elles etaient definitives et numerotees. On remplace ce
-- seul garde-fou sans dupliquer le moteur comptable complet.
do $accounting_legacy_guard$
declare source_definition text;patched_definition text;
begin
  source_definition:=pg_get_functiondef('public._generate_document_accounting_entry(uuid)'::regprocedure);
  patched_definition:=replace(
    source_definition,
    $$if doc.id is null or doc.finalized_at is null or doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice') then return null;end if;$$,
    $$if doc.id is null or not public._piloz_accounting_document_is_final(doc.id) or doc.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note','purchase_invoice') then return null;end if;$$
  );
  if patched_definition=source_definition then
    raise exception 'accounting_legacy_guard_patch_not_applied';
  end if;
  execute patched_definition;
end $accounting_legacy_guard$;

-- Toute transition vers un etat definitif tente la generation. La fonction
-- d'ecriture est idempotente et refuse les brouillons.
create or replace function public.accounting_document_finalized_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if public._piloz_accounting_document_is_final(new.id) then
    perform public._generate_document_accounting_entry(new.id);
  end if;
  return new;
end $$;

drop trigger if exists documents_generate_accounting on public.documents;
create trigger documents_generate_accounting
after insert or update of finalized_at,validated_at,status,number on public.documents
for each row execute function public.accounting_document_finalized_trigger();

-- Le rattrapage ne masque plus les anomalies : il retourne le nombre de
-- pieces eligibles, celles deja comptabilisees et un echantillon des erreurs.
create or replace function public.backfill_company_accounting_entries(target_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  doc_row record;
  generated_id uuid;
  eligible_count integer:=0;
  existing_count integer:=0;
  created_count integer:=0;
  failure_count integer:=0;
  failure_details jsonb:='[]'::jsonb;
begin
  if not public.has_company_permission(target_company_id,'accounting.entries.read') then
    raise exception 'forbidden' using errcode='42501';
  end if;

  select count(*) into eligible_count
  from public.documents document
  where document.company_id=target_company_id
    and public._piloz_accounting_document_is_final(document.id);

  select count(*) into existing_count
  from public.documents document
  where document.company_id=target_company_id
    and public._piloz_accounting_document_is_final(document.id)
    and exists(
      select 1 from public.accounting_entries entry
      where entry.company_id=target_company_id
        and entry.source_type='document'
        and entry.source_id=document.id
        and entry.event_kind='original'
    );

  for doc_row in
    select document.id,document.number,document.issue_date,document.document_type
    from public.documents document
    where document.company_id=target_company_id
      and public._piloz_accounting_document_is_final(document.id)
      and not exists(
        select 1 from public.accounting_entries entry
        where entry.company_id=target_company_id
          and entry.source_type='document'
          and entry.source_id=document.id
          and entry.event_kind='original'
      )
    order by document.issue_date,document.created_at
  loop
    begin
      generated_id:=public._generate_document_accounting_entry(doc_row.id);
      if generated_id is null then
        failure_count:=failure_count+1;
        if jsonb_array_length(failure_details)<10 then
          failure_details:=failure_details||jsonb_build_array(jsonb_build_object(
            'document_id',doc_row.id,'number',doc_row.number,'issue_date',doc_row.issue_date,
            'document_type',doc_row.document_type,'code','accounting_entry_not_generated',
            'message','La piece definitive n''a produit aucune ecriture.'
          ));
        end if;
      else
        created_count:=created_count+1;
      end if;
    exception when others then
      failure_count:=failure_count+1;
      if jsonb_array_length(failure_details)<10 then
        failure_details:=failure_details||jsonb_build_array(jsonb_build_object(
          'document_id',doc_row.id,'number',doc_row.number,'issue_date',doc_row.issue_date,
          'document_type',doc_row.document_type,'code',sqlstate,'message',sqlerrm
        ));
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'eligible',eligible_count,'existing',existing_count,'created',created_count,
    'failed',failure_count,'failures',failure_details
  );
end $$;

-- Diagnostic separe de la previsualisation : l'interface peut maintenant
-- distinguer une periode vide, des pieces deja exportees et un rattrapage en
-- erreur au lieu d'afficher le meme zero dans tous les cas.
create or replace function public.diagnose_accounting_export(
  target_company_id uuid,
  target_journal_type text,
  target_starts_on date,
  target_ends_on date
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  eligible_documents integer:=0;
  generated_entries integer:=0;
  available_entries integer:=0;
  already_exported_entries integer:=0;
begin
  if not public.has_company_permission(target_company_id,'accounting.exports.manage') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if target_ends_on<target_starts_on then
    raise exception 'invalid_period' using errcode='22023';
  end if;

  select count(*) into eligible_documents
  from public.documents document
  where document.company_id=target_company_id
    and document.issue_date between target_starts_on and target_ends_on
    and public._piloz_accounting_document_is_final(document.id)
    and (
      target_journal_type='fec'
      or (target_journal_type='sales' and document.document_type<>'purchase_invoice')
      or (target_journal_type='purchases' and document.document_type='purchase_invoice')
    );

  select
    count(*),
    count(*) filter(where not exists(
      select 1
      from public.accounting_export_batch_entries exported
      join public.accounting_export_batches batch on batch.id=exported.export_batch_id
      where exported.accounting_entry_id=entry.id and batch.status='validated'
    )),
    count(*) filter(where exists(
      select 1
      from public.accounting_export_batch_entries exported
      join public.accounting_export_batches batch on batch.id=exported.export_batch_id
      where exported.accounting_entry_id=entry.id and batch.status='validated'
    ))
  into generated_entries,available_entries,already_exported_entries
  from public.accounting_entries entry
  join public.accounting_journals journal on journal.id=entry.journal_id
  where entry.company_id=target_company_id
    and entry.entry_date between target_starts_on and target_ends_on
    and (target_journal_type='fec' or journal.journal_type=target_journal_type);

  return jsonb_build_object(
    'eligible_documents',eligible_documents,
    'generated_entries',generated_entries,
    'available_entries',available_entries,
    'already_exported_entries',already_exported_entries,
    'missing_entries',greatest(eligible_documents-generated_entries,0)
  );
end $$;

revoke all on function public._piloz_accounting_document_is_final(uuid) from public,anon,authenticated;
revoke all on function public.backfill_company_accounting_entries(uuid) from public,anon;
revoke all on function public.diagnose_accounting_export(uuid,text,date,date) from public,anon;
grant execute on function public.backfill_company_accounting_entries(uuid) to authenticated;
grant execute on function public.diagnose_accounting_export(uuid,text,date,date) to authenticated;

alter table public.company_fiscal_configurations alter column schema_version set default '202607260085';
update public.company_fiscal_configurations set
  application_version='0.9.0-compliance.39',schema_version='202607260085',updated_at=now()
where application_version is distinct from '0.9.0-compliance.39'
   or schema_version is distinct from '202607260085';

commit;
