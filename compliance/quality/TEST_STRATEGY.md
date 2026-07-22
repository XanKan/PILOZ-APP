# Stratégie de test

## Niveaux

- Domaine : calculs, validation canonique, qualification et vérificateur d'archive dans les pages de test/Node.
- Intégration : application de toutes les migrations et parcours devis → facture → paiement → correction → clôture → archive → modèle canonique → simulation avec PGlite.
- Sécurité : privilèges SQL, écriture directe refusée, séparation locataire, recherche de secrets.
- Interface : rendu des routes, éditeurs, réponses API vides/non JSON et régressions via Chrome headless.
- Infrastructure : tests de migration et restauration dans un projet Supabase isolé avant production.

## Données

Utiliser uniquement des identités synthétiques explicites. Ne jamais copier une base réelle dans un poste ou artefact CI sans anonymisation et autorisation. Les cas limites incluent décimales, multiples TVA, 10 000 lignes, concurrence, idempotence, fichier altéré et entreprise adverse.

## Critères de release

Tous les tests automatisés passent, aucun secret, migration complète, CNAME exact, rapport des limitations à jour. Les fonctionnalités nécessitant KMS, profil normatif ou plateforme restent bloquées. Un échec fiscal, RLS, secret, migration ou restauration est bloquant.

## Preuves

La CI conserve logs et commit. Un dossier de preuves reproductible est généré par `generate-compliance-evidence-pack`. Les tests nécessitant une infrastructure externe ont un rapport daté signé par l'opérateur ; l'absence de rapport reste un échec/non exécuté.
