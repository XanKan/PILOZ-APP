# Contrôle de sauvegarde et de restauration

## Périmètre minimal

La sauvegarde doit couvrir PostgreSQL, les objets privés `company-files`, les PDF, futurs XML, archives, migrations, configurations non secrètes, clés publiques et métadonnées de version. Les secrets et clés privées relèvent du coffre de secrets/KMS et d'une procédure séparée.

## État vérifié au 22 juillet 2026

Le dépôt ne donne aucun accès au tableau de bord du projet Supabase ni à son plan de sauvegarde. L'activation de PITR, les rétentions de backups, la réplication Storage et l'existence d'une copie hors fournisseur ne sont donc **pas vérifiées**. Aucune affirmation de sauvegarde opérationnelle n'est faite.

## Procédure de test à exécuter dans un environnement isolé

1. Geler l'identifiant du backup, le commit, la version du schéma et l'heure UTC.
2. Exporter la base et le bucket privé sans utiliser une clé dans une commande journalisée.
3. Restaurer vers un projet Supabase de test distinct.
4. Comparer les nombres de documents, snapshots, événements, paiements, clôtures, archives et objets Storage.
5. Exécuter `verify_fiscal_event_chain` pour chaque entreprise restaurée.
6. Exécuter `verify_fiscal_archive_record` puis `verify-fiscal-archive` sur un échantillon exporté.
7. Vérifier séquences, clés étrangères, hash PDF, RLS et tests inter-entreprises.
8. Documenter RPO, RTO, erreurs et décision de validation. Détruire l'environnement de test selon la procédure RGPD.

## Critères d'échec

Un événement manquant, une séquence divergente, une empreinte invalide, un objet Storage absent, une RLS permissive ou un comptage différent invalide le test. La restauration ne doit jamais être effectuée sur la production pour un simple exercice.

## Actions externes requises

- confirmer le plan Supabase et activer la politique appropriée ;
- définir RPO/RTO et une copie hors compte principal ;
- organiser et dater un exercice réel de restauration ;
- conserver son rapport signé par les responsables ;
- traiter séparément la sauvegarde et la récupération des clés du KMS.
