begin;

-- Version sémantique de la pré-release qualité. Les entreprises déjà activées
-- conservent leur version effective ; seules les configurations non activées
-- passent à la nouvelle valeur par défaut.
alter table public.company_fiscal_configurations
  alter column application_version set default '0.9.0-compliance.1',
  alter column schema_version set default '202607220044';

update public.company_fiscal_configurations
set application_version='0.9.0-compliance.1',schema_version='202607220044',updated_at=now()
where activated_at is null and mode in('off','test')
  and application_version='2026.07-compliance';

commit;
