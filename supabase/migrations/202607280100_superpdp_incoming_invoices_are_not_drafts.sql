-- Les factures reçues d'une PA sont des documents émis par un fournisseur :
-- elles doivent être traitées, mais ne sont jamais des brouillons PILOZ.
update public.documents
set status='pending',updated_at=now()
where document_type='purchase_invoice'
  and status='draft'
  and coalesce(metadata->>'electronic_source','')='superpdp_sandbox';
