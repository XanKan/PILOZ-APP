# Procédure de sauvegarde et restauration

Cette procédure complète `BACKUP_AND_RESTORE_CONTROL.md`. Son exécution réelle n'est pas prouvée par le dépôt.

Sauvegarder PostgreSQL, Storage privé, migrations, fonctions, paramètres non secrets, archives et clés publiques. Les secrets/KMS suivent une procédure séparée. Étiqueter backup, projet, région, heure UTC, commit, schéma, chiffrement, rétention et opérateur.

Restaurer uniquement dans un projet isolé : déployer le schéma, restaurer base et Storage, réappliquer les paramètres secrets, puis comparer comptages, séquences, relations, hash PDF, chaînes, clôtures, archives et RLS. Exécuter toutes les suites. Consigner RPO/RTO mesurés, anomalies et décision.

Le propriétaire exploitation planifie au moins un exercice annuel et après changement majeur d'infrastructure. Supabase PITR, rétention et copie hors compte sont à confirmer dans le projet réel.
