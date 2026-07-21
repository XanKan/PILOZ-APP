begin;

-- La migration 018 arrête de verrouiller les *nouveaux* devis, mais les
-- devis déjà finalisés sous l'ancien système restaient bloqués en lecture
-- seule (finalized_at/validated_at/locked_at déjà posés, ou statut hérité
-- 'finalized'/'validated' qui n'existe plus pour un devis). On lève ce
-- verrou historique une bonne fois pour toutes : le numéro déjà attribué
-- est conservé, seul l'état de verrouillage est effacé.
update public.documents set
  status=case when status in('finalized','validated') then 'draft' else status end,
  finalized_at=null,
  finalized_by=null,
  validated_at=null,
  locked_at=null,
  updated_at=now()
where document_type='quote'
  and (finalized_at is not null or validated_at is not null or locked_at is not null or status in('finalized','validated'));

commit;
