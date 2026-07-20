# Mise en service PILOZ ERP

Le dépôt reste compatible GitHub Pages : toutes les vues utilisent des fragments `#...`.
Cette procédure n'a pas été exécutée lors de la refonte : aucun déploiement, commit ou push n'a été effectué.

## Ordre obligatoire

1. Sauvegarder la base Supabase et le bucket historique `fichiers`.
2. Appliquer les cinq migrations dans leur ordre de nom :
   - `202607200001_phase1_foundation.sql`
   - `202607200002_erp_core.sql`
   - `202607200003_erp_workflows.sql`
   - `202607200004_company_verifications.sql`
   - `202607200005_erp_completeness.sql`
3. Déployer les Edge Functions du dossier `supabase/functions`.
4. Configurer les secrets `RESEND_API_KEY` et `EMAIL_FROM`.
5. Ajouter `https://app.piloz.fr` aux origines et URL de redirection Auth autorisées.
6. Vérifier la création des buckets privés `company-assets` et `company-files`, ainsi que leurs politiques Storage.
7. Tester avec deux entreprises et trois comptes (owner, membre, utilisateur externe).
8. Exécuter `supabase/tests/rls_acceptance.sql`, puis la matrice `docs/ACCEPTANCE.md`.
9. Déployer les fichiers statiques seulement après validation des tests.

La clé `SUPABASE_SERVICE_ROLE_KEY` est utilisée exclusivement dans les Edge Functions. Elle ne doit jamais être ajoutée à `index.html`, aux assets publics ou au stockage local.

## Edge Functions

- `company-search`
- `address-search`
- `request-company-email-confirmation`
- `confirm-company-email`
- `save-document-template`
- `send-document-email`
- `request-company-phone-verification`
- `confirm-company-phone`

Sans `RESEND_API_KEY`, l’application indique que l’envoi d’e-mails n’est pas configuré ; aucune validation fictive n’est produite.

La vérification SMS est facultative. Pour l’activer, configurer `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` et `TWILIO_FROM_NUMBER`. Sans ces secrets, le téléphone reste affiché comme non vérifié.

## Contrôles avant ouverture

- confirmer que les URL Auth autorisées contiennent exactement le domaine de production ;
- vérifier que la clé `service_role` n'est présente dans aucun fichier public ni secret du navigateur ;
- exécuter les scénarios multi-entreprises avec des JWT réels ;
- vérifier les e-mails Resend et, si activé, les SMS Twilio sur un environnement de test ;
- tester un flux complet devis → commande → réservation → livraison partielle → livraison complète ;
- tester un flux achat → réception partielle → coût moyen → retour fournisseur ;
- conserver `CNAME` inchangé avec la valeur `app.piloz.fr`.
