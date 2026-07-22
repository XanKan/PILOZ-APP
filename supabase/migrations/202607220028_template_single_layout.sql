begin;

-- Le choix de mise en page (Classique/Moderne/Compact) est retiré de
-- l'éditeur : un seul style visuel désormais, piloté uniquement par la
-- couleur d'accent, les bordures, le fond des tableaux et le texte.
-- Normalise les versions existantes pour rester cohérent avec l'éditeur.
update public.document_template_versions set layout_key='classic' where layout_key<>'classic';

commit;
