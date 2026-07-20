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

La sixième migration ajoute les contacts clients, catégories, taux de TVA, étapes du pipeline, activités, relances, échéanciers et widgets. Elle ajoute aussi les RPC atomiques de conversion devis-facture, paiement et mouvement de stock, ainsi que leurs politiques RLS. Les septième et huitième migrations retirent l’exécution anonyme héritée puis réduisent les droits des utilisateurs authentifiés à une liste explicite de RPC métier.

Fonctions Edge utilisées :

- `company-search`
- `address-search`
- `request-company-email-confirmation`
- `confirm-company-email`
- `save-document-template`
- `send-document-email`
- `request-company-phone-verification`
- `confirm-company-phone`

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
