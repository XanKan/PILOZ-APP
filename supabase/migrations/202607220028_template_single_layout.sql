begin;

-- Conserve les mises en page Classique, Moderne et Compact. Seules les
-- anciennes valeurs inconnues sont normalisées, sans écraser un choix valide.
update public.document_template_versions set layout_key='classic'
where layout_key is null or layout_key not in('classic','modern','compact');

commit;
