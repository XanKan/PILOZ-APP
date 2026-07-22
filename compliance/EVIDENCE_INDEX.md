# Index des preuves

Ce fichier indexe les preuves disponibles et celles restant à produire. Une preuve est `disponible` seulement si elle peut être reproduite sans dépendre d'une affirmation manuelle.

| ID | Preuve | Emplacement | État initial | Producteur |
|---|---|---|---|---|
| E-001 | Historique Git et commit source | `.git` / GitHub | Disponible | Git |
| E-002 | Migrations ordonnées | `supabase/migrations/` | Disponible dans le dépôt ; application production à vérifier | Équipe technique |
| E-003 | Contrôles structurels RLS/RPC | `supabase/tests/` | Disponibles ; environnement production à exécuter | PostgreSQL/pgTAP |
| E-004 | Parcours devis/facture embarqué | `tests/document-lifecycle-pglite.cjs` | Réussi le 22/07/2026 | PGlite |
| E-005 | Tests calculs et rendu | `tests/` | Disponibles ; rapport consolidé à produire | Navigateur headless |
| E-006 | Analyse initiale des écarts | `compliance/COMPLIANCE_GAP_ANALYSIS.md` | Disponible | Audit interne |
| E-007 | Matrice de conformité | `compliance/COMPLIANCE_MATRIX.csv` | Initialisée ; clauses AFNOR à compléter | Responsable conformité |
| E-008 | Registre des risques | `compliance/RISK_REGISTER.md` | Disponible | Responsable conformité |
| E-009 | Vérification de chaîne fiscale | `verify_fiscal_event_chain` et test PGlite | Disponible dans le code ; à exécuter en production | PostgreSQL |
| E-010 | Manifestes d'archives | `fiscal_archives`, `ARCHIVE_FORMAT.md` | Génération et contrôle testés ; déploiement Supabase requis | `create_fiscal_archive` |
| E-011 | Signature et certificat de clé | KMS externe | Non configurés | Exploitation sécurité |
| E-012 | Exercice de restauration | `BACKUP_AND_RESTORE_CONTROL.md` | Procédure disponible ; exercice réel non exécuté | Exploitation |
| E-017 | Vérificateur d'archive autonome | `scripts/verify-fiscal-archive.mjs` | Altération détectée par test automatisé | Node.js |
| E-018 | Générateur de dossier de preuves | `scripts/generate-compliance-evidence-pack.mjs` | Exécution locale réussie ; dossier non signé | Node.js |
| E-019 | Modèle canonique de facture | `electronic_invoice_records`, `tests/electronic-invoice.html` | Génération JSON testée ; 11/11 contrôles | PostgreSQL et navigateur |
| E-020 | Blocage des formats sans profil | `check_electronic_format_profile`, adaptateurs serveur | UBL/CII/Factur-X bloqués comme attendu | PostgreSQL et navigateur |
| E-021 | Simulation de plateforme idempotente | `run_platform_sandbox_simulation`, test PGlite | Réussie, sans statut transmis | PostgreSQL |
| E-022 | Préclassification e-reporting | `classifyTransactionForFrenchEInvoicing`, `e_reporting_records` | Cas B2B/B2C/paiement/incomplet testés | Navigateur et PostgreSQL |
| E-023 | Système qualité et traçabilité | `compliance/quality/`, `compliance-checks.yml` | Documents et contrôles techniques disponibles ; application organisationnelle à prouver | Équipe qualité |
| E-024 | Manifeste de release | `VERSION`, `RELEASE_MANIFEST.json`, `verify-release.mjs` | Cohérence version/schéma/CNAME testée | CI |
| E-025 | Contrôle d’intégrité daté | `compliance_integrity_checks`, `run_company_integrity_check` | Implémenté et testé localement ; migration production requise | PostgreSQL |
| E-026 | Contrôle du moindre privilège | `has_company_permission`, triggers de garde | Rôles lecture seule et propriétaire testés localement | PostgreSQL |
| E-027 | Registre de demandes RGPD | `data_subject_requests`, `data_subject_request_items` | Infrastructure testée ; procédure juridique à valider | DPO et PostgreSQL |
| E-028 | Activation de production bloquée | `evaluate_fiscal_activation`, `activate_fiscal_engine` | Blocage sans KMS/preuves/profils testé | PostgreSQL |
| E-029 | Absence de certification fictive | `company_software_certifications`, écran À propos | Table vide par défaut et insertion navigateur refusée | PostgreSQL et navigateur |
| E-030 | Rapport de tests final local | `reports/FINAL_TEST_REPORT_2026-07-22.md` | Migrations, 14 suites navigateur, archives et release réussies | CI locale |
| E-031 | Incidents de paiement append-only | migration 046 et test PGlite | Trop-perçu et deux remboursements partiels testés sans mutation | PostgreSQL embarqué |
| E-032 | Export de droit d’accès | `generate_data_subject_export` | Payload remis sans persistance, empreinte et événement conservés | PostgreSQL embarqué |
| E-033 | Maintenance fiscale contrôlée | migration 047 et procédure de production | Détection/reprise implémentées ; Cron production à créer | PostgreSQL/Supabase Cron |
| E-034 | Déploiement Supabase non interactif | `scripts/deploy-supabase-production.ps1` | Dry-run par défaut, sauvegarde exigée avant application | Exploitation |
| E-013 | Validation UBL/CII/Factur-X | Rapports de validateurs officiels | Non exécutée | Intégration e-invoicing |
| E-014 | Accusés de plateforme agréée | Connecteur réel | Non configurés | Plateforme retenue |
| E-015 | Revue juridique | Avis signé et versionné | Non fourni | Conseil juridique |
| E-016 | Audit/certification | Rapport et certificat réel | Non obtenu | Organisme accrédité |

## Règles de constitution

- Aucun secret, token, IBAN complet, clé privée ou donnée client réelle dans un dossier de preuves.
- Les exemples doivent être synthétiques et marqués comme tels.
- Chaque rapport doit inclure version, commit, schéma, date UTC, outil et résultat.
- Une preuve échouée ou absente reste visible ; elle n'est jamais remplacée par un statut positif.
