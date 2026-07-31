begin;

-- L'emission electronique des factures clients est reportee.
-- La reception des factures fournisseurs reste active.
drop trigger if exists documents_queue_superpdp_after_finalization on public.documents;

update public.superpdp_jobs
set status = 'cancelled',
    completed_at = coalesce(completed_at, now()),
    locked_at = null,
    last_error_code = 'electronic_invoice_outbound_disabled'
where job_type = 'send_document'
  and status in ('pending', 'retry_scheduled', 'processing');

create or replace function public.queue_finalized_invoice_for_superpdp()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return new;
end;
$$;

comment on function public.queue_finalized_invoice_for_superpdp()
is 'Emission electronique client desactivee. La reception des factures fournisseurs reste active.';

commit;
