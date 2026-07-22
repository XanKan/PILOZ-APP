begin;

-- Une annulation comptable totale neutralise également les échéanciers et
-- relances encore ouverts. La date de l'avoir ne peut pas précéder la facture.
create or replace function public.create_full_credit_note_v2(
  target_invoice_id uuid,credit_reason text,credit_date date,create_replacement boolean default false
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare source public.documents%rowtype; credit_id uuid; replacement_id uuid; finalized_credit jsonb;
begin
  if nullif(trim(credit_reason),'') is null then raise exception 'credit_reason_required'; end if;
  if credit_date is null then raise exception 'credit_date_required'; end if;
  select * into source from public.documents where id=target_invoice_id for update;
  if source.id is null or source.document_type not in('invoice','deposit_invoice','balance_invoice')
    or not public.is_company_member(source.company_id) then raise exception 'invoice_not_found' using errcode='P0002'; end if;
  if source.finalized_at is null and source.validated_at is null then raise exception 'invoice_must_be_finalized'; end if;
  if source.status in('cancelled','archived') then raise exception 'invoice_already_cancelled'; end if;
  if source.issue_date is not null and credit_date<source.issue_date then raise exception 'credit_date_before_invoice'; end if;

  credit_id:=public.create_credit_note(source.id,trim(credit_reason),null);
  update public.documents set issue_date=credit_date,due_date=credit_date,
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('credit_date',credit_date,'credit_reason',trim(credit_reason)),updated_at=now()
  where id=credit_id and status='draft';
  finalized_credit:=public.finalize_document(credit_id);

  update public.documents set status='cancelled',updated_at=now() where id=source.id;
  update public.payment_schedules set status='cancelled',updated_at=now()
  where document_id=source.id and status in('pending','partial');
  update public.reminders set status='cancelled',updated_at=now()
  where document_id=source.id and status='pending';
  update public.document_links set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
    'reason',trim(credit_reason),'credit_date',credit_date,'cancellation_kind','full'
  ) where source_document_id=source.id and target_document_id=credit_id and link_type='credit_note';

  if create_replacement then
    insert into public.documents(
      company_id,document_type,client_id,status,issue_date,due_date,subject,client_reference,currency,language,
      payment_terms,payment_method,internal_notes,public_notes,discount_rate,source_document_id,root_document_id,
      opportunity_id,assigned_user_id,template_id,metadata,created_by
    ) values(
      source.company_id,'invoice',source.client_id,'draft',credit_date,null,source.subject,source.client_reference,
      source.currency,source.language,source.payment_terms,source.payment_method,source.internal_notes,source.public_notes,
      source.discount_rate,source.id,coalesce(source.root_document_id,source.id),source.opportunity_id,source.assigned_user_id,
      source.template_id,coalesce(source.metadata,'{}'::jsonb)||jsonb_build_object(
        'replacement_of',source.id,'created_from_cancellation',true,'credit_note_id',credit_id
      ),auth.uid()
    ) returning id into replacement_id;
    perform public._piloz_copy_document_lines(source.id,replacement_id);
    insert into public.document_links(company_id,source_document_id,target_document_id,link_type,metadata,created_by)
    values(source.company_id,source.id,replacement_id,'related',jsonb_build_object('relation','replacement_invoice'),auth.uid()),
      (source.company_id,credit_id,replacement_id,'related',jsonb_build_object('relation','replacement_for_credit'),auth.uid());
  end if;

  insert into public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data,created_by)
  values(source.company_id,auth.uid(),'invoice.cancelled_with_credit','document',source.id,
    jsonb_build_object('status',source.status),jsonb_build_object('status','cancelled','credit_note_id',credit_id,
      'replacement_invoice_id',replacement_id,'reason',trim(credit_reason),'credit_date',credit_date,
      'payment_schedules_cancelled',true,'pending_reminders_cancelled',true),auth.uid());
  return jsonb_build_object('source_invoice_id',source.id,'credit_note_id',credit_id,
    'replacement_invoice_id',replacement_id,'credit_number',finalized_credit->>'number');
end
$$;

revoke all on function public.create_full_credit_note_v2(uuid,text,date,boolean) from public,anon;
grant execute on function public.create_full_credit_note_v2(uuid,text,date,boolean) to authenticated;

commit;
