# Déploiement de PILOZ ERP

Le front est un site statique compatible GitHub Pages. Les vues utilisent des fragments `#...` et le fichier `CNAME` contient exclusivement `app.piloz.fr`.

## Supabase

Appliquer les migrations dans l’ordre :

1. `202607200001_phase1_foundation.sql`
2. `202607200002_erp_core.sql`
3. `202607200003_erp_workflows.sql`
4. `202607200004_company_verifications.sql`
5. `202607200005_erp_completeness.sql`
6. `202607200006_modern_commercial_suite.sql`
7. `202607200007_harden_function_permissions.sql`
8. `202607200008_minimize_authenticated_rpc_surface.sql`
9. `202607200009_balance_invoice_validation.sql`
10. `202607210010_functional_completeness.sql`
11. `202607210011_backfill_legacy_company_settings.sql`
12. `202607210012_subscriptions_and_plans.sql`

Puis appliquer **tous** les fichiers suivants selon l'ordre lexical jusqu'à `202607220044_release_version.sql`. La liste ci-dessus est historique et non exhaustive ; le fichier portant le plus grand préfixe définit la version de schéma attendue par `compliance/RELEASE_MANIFEST.json`. Ne jamais sélectionner seulement certaines migrations intermédiaires.

La sixième migration ajoute les contacts clients, catégories, taux de TVA, étapes du pipeline, activités, relances, échéanciers et widgets. Elle ajoute aussi les RPC atomiques de conversion devis-facture, paiement et mouvement de stock, ainsi que leurs politiques RLS. Les septième et huitième migrations retirent l’exécution anonyme héritée puis réduisent les droits des utilisateurs authentifiés à une liste explicite de RPC métier. La dixième migration ajoute notamment `documents.sent_at`, les champs comptables/légaux de `company_settings`, et les RPC `cancel_document_payment`/`reopen_invoice_for_correction` — **cette liste doit être tenue à jour à chaque nouvelle migration** ; un déploiement qui s'arrête avant la fin de la liste laisse l'application dans un état incohérent (colonnes ou fonctions absentes malgré un code applicatif qui les suppose présentes).

Fonctions Edge utilisées :

- `company-search`
- `address-search`
- `request-company-email-confirmation`
- `confirm-company-email`
- `save-document-template`
- `send-document-email`
- `request-company-phone-verification`
- `confirm-company-phone`
- `generate-document-pdf`
- `export-fiscal-archive`
- `platform-connector`

Les migrations 039 à 044 installent la fondation fiscale, le journal/paiements/clôtures, les archives, le modèle canonique, le sandbox de plateforme et la version de release. Elles doivent d'abord être appliquées et testées sur un projet isolé. Le moteur reste désactivé par défaut ; ne pas activer le mode production sans KMS, sauvegarde vérifiée, profils électroniques officiels et validations externes.

Les secrets `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`, `EMAIL_FROM` et les identifiants Twilio ne doivent jamais être présents dans le dépôt ni dans le navigateur.

## Publication GitHub Pages

Avant un push sur `main` :

1. vérifier le dépôt et récupérer `origin/main` avec rebase ;
2. contrôler `CNAME`, les chemins relatifs et l’absence de secrets ;
3. exécuter les tests de calcul et de rendu ;
4. vérifier la migration et les politiques RLS ;
5. pousser sans `--force`, puis contrôler le workflow Pages et `https://app.piloz.fr`.

## Services optionnels

Sans secrets Resend, l’envoi d’e-mails répond avec une erreur de configuration claire. Sans secrets Twilio, aucun SMS fictif n’est émis et le numéro reste non vérifié. Ces intégrations s’activent uniquement depuis les secrets du projet Supabase.
