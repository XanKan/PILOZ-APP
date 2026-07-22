begin;

-- Empêche qu'un numéro officiel plus récent soit associé à une date d'émission
-- antérieure. Les brouillons restent libres et peuvent être corrigés avant leur
-- finalisation. Le verrou consultatif sérialise les finalisations d'une même
-- série documentaire, y compris lorsque deux utilisateurs valident en parallèle.
create or replace function public.enforce_invoice_issue_date_chronology()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  latest_issue_date date;
begin
  if old.finalized_at is not null
    or new.finalized_at is null
    or new.document_type not in('invoice','deposit_invoice','balance_invoice','credit_note') then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.company_id::text||':'||new.document_type,0));

  select max(document.issue_date)
  into latest_issue_date
  from public.documents document
  where document.company_id=new.company_id
    and document.document_type=new.document_type
    and document.id<>new.id
    and document.finalized_at is not null;

  if latest_issue_date is not null and new.issue_date<latest_issue_date then
    raise exception 'invoice_issue_date_before_last_finalized:%',latest_issue_date
      using errcode='22023',
        detail='La date d''émission doit respecter l''ordre chronologique de la série de numérotation.';
  end if;

  return new;
end
$$;

revoke all on function public.enforce_invoice_issue_date_chronology() from public,anon,authenticated;

drop trigger if exists documents_enforce_issue_date_chronology on public.documents;
create trigger documents_enforce_issue_date_chronology
before update of finalized_at on public.documents
for each row
when(old.finalized_at is null and new.finalized_at is not null)
execute function public.enforce_invoice_issue_date_chronology();

alter table public.company_fiscal_configurations
  alter column schema_version set default '202607230048';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.4',schema_version='202607230048',updated_at=now()
where schema_version is distinct from '202607230048'
   or application_version is distinct from '0.9.0-compliance.4';

commit;
