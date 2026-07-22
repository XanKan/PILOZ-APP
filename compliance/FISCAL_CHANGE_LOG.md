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

## 0.9.0-compliance.2 — 22 juillet 2026

- Modification : contrôle d’accès fiscal, RGPD préparatoire, observabilité d’intégrité, activation conditionnelle et transparence UI.
- Composants : migration 045, `erp-compliance.js`, documentation `compliance/privacy/`.
- Données : membres, preuves, anomalies, demandes de droits, règles de conservation et certificats réels éventuels.
- Catégorie : impact fiscal important, réévaluation de conformité requise.
- Risques : migration production non exécutée, revue juridique absente, KMS/profils/plateforme/sauvegarde non validés.
- Tests : toutes migrations PGlite, rôles, activation bloquée, contrôle d’intégrité, table de certificats vide et vues navigateur.
- Migration : additive ; élargissement contrôlé de la liste des rôles, aucune activation ou certification automatique.
- Décision : pré-release technique ; moteur production maintenu désactivé.
- Validation : technique interne uniquement. DPO, juridique, sécurité, AFNOR et organisme certificateur requis.
