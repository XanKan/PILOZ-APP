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
| E-013 | Validation UBL/CII/Factur-X | Rapports de validateurs officiels | Non exécutée | Intégration e-invoicing |
| E-014 | Accusés de plateforme agréée | Connecteur réel | Non configurés | Plateforme retenue |
| E-015 | Revue juridique | Avis signé et versionné | Non fourni | Conseil juridique |
| E-016 | Audit/certification | Rapport et certificat réel | Non obtenu | Organisme accrédité |

## Règles de constitution

- Aucun secret, token, IBAN complet, clé privée ou donnée client réelle dans un dossier de preuves.
- Les exemples doivent être synthétiques et marqués comme tels.
- Chaque rapport doit inclure version, commit, schéma, date UTC, outil et résultat.
- Une preuve échouée ou absente reste visible ; elle n'est jamais remplacée par un statut positif.
