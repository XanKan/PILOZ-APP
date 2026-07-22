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
| E-009 | Vérification de chaîne fiscale | Rapport à générer | Manquante | `verify_fiscal_chain` |
| E-010 | Manifestes d'archives | Storage fiscal privé | Manquants | `fiscalArchiveService` |
| E-011 | Signature et certificat de clé | KMS externe | Non configurés | Exploitation sécurité |
| E-012 | Exercice de restauration | Rapport horodaté | Non exécuté | Exploitation |
| E-013 | Validation UBL/CII/Factur-X | Rapports de validateurs officiels | Non exécutée | Intégration e-invoicing |
| E-014 | Accusés de plateforme agréée | Connecteur réel | Non configurés | Plateforme retenue |
| E-015 | Revue juridique | Avis signé et versionné | Non fourni | Conseil juridique |
| E-016 | Audit/certification | Rapport et certificat réel | Non obtenu | Organisme accrédité |

## Règles de constitution

- Aucun secret, token, IBAN complet, clé privée ou donnée client réelle dans un dossier de preuves.
- Les exemples doivent être synthétiques et marqués comme tels.
- Chaque rapport doit inclure version, commit, schéma, date UTC, outil et résultat.
- Une preuve échouée ou absente reste visible ; elle n'est jamais remplacée par un statut positif.
