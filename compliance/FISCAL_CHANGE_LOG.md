# Journal des changements fiscaux

## 0.9.0-compliance.1 — 22 juillet 2026

- Modification : fondation de conformité fiscale, registre, archives et préparation e-invoicing.
- Composants : migrations 039 à 044, RPC de finalisation/paiement/clôture/archive, Edge Functions d'export/sandbox, domaines JavaScript.
- Données : documents, numéros, snapshots, paiements, événements, clôtures, archives, modèles canoniques, transmissions simulées.
- Catégorie : impact fiscal important, réévaluation de conformité requise.
- Risques : production non migrée, absence KMS, profils XP/UBL/CII absents, plateforme non choisie.
- Tests : PGlite, Chrome headless, vérificateur d'archive, secret/CNAME.
- Migrations : additives ; données historiques marquées `legacy_unsecured`, aucune signature rétroactive.
- Décision : pré-release technique ; moteur production non activé.
- Validation : technique interne uniquement. Revues juridique, AFNOR, organisme certificateur, sécurité et plateforme requises.

Chaque future entrée doit conserver version, date, modification, composants, données, risque, tests, migration, décision et validations.
