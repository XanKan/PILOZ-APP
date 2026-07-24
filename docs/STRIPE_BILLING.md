# Facturation des abonnements Piloz avec Stripe

## Ce qui est automatisé

- Piloz crée les produits et tarifs Stripe à partir des offres versionnées en base.
- Un premier abonnement passe par Stripe Checkout.
- Un abonnement Stripe existant ouvre le Customer Portal, sans créer de doublon.
- Le webhook signé synchronise l'abonnement, les factures, paiements et remboursements.
- Le navigateur ne reçoit jamais la clé secrète Stripe ni un numéro de carte complet.

## Configuration initiale (une seule fois)

1. Dans Stripe, ouvrir **Mode test** pour la recette, puis **Développeurs > Clés API**.
2. Dans Supabase, ouvrir le projet `hpxcbemezvynofxiffzs`, puis **Edge Functions > Secrets**.
3. Ajouter `STRIPE_SECRET_KEY` avec la clé secrète Stripe du mode choisi (`sk_test_...` en recette ou `sk_live_...` en production).
4. Déployer les fonctions :

   ```powershell
   npx.cmd --yes supabase@2.109.1 functions deploy stripe-billing --project-ref hpxcbemezvynofxiffzs
   npx.cmd --yes supabase@2.109.1 functions deploy stripe-webhook --project-ref hpxcbemezvynofxiffzs --no-verify-jwt
   ```

5. Dans Stripe, ouvrir **Développeurs > Webhooks > Ajouter une destination** et saisir :

   ```text
   https://hpxcbemezvynofxiffzs.supabase.co/functions/v1/stripe-webhook
   ```

6. Sélectionner au minimum ces événements :

   - `checkout.session.completed`
   - `customer.subscription.created`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.finalized`
   - `invoice.paid`
   - `invoice.payment_failed`
   - `charge.refunded`

7. Copier le secret de signature du webhook (`whsec_...`) dans un secret Supabase nommé `STRIPE_WEBHOOK_SECRET`.
8. Dans Stripe, ouvrir **Paramètres > Facturation > Portail client** et activer les fonctions souhaitées : changement de carte, factures, résiliation et changement d'offre.
9. Appliquer la migration `202607240057_stripe_billing.sql` avec le script de déploiement Supabase du dépôt.
10. Exécuter `scripts/post-deploy-production-checks.sql` dans le SQL Editor. Le résultat doit contenir `"ok": true` et `"schema_version": "202607240057"`.

Ne jamais coller une clé `sk_...` ou `whsec_...` dans Git, dans le navigateur, dans une capture d'écran ou dans une conversation. Si une clé a été exposée, la révoquer immédiatement dans Stripe puis la remplacer dans Supabase.

## Recette avant passage en production

1. Conserver les clés `sk_test_...` et le webhook en mode test.
2. Depuis **Paramètres > Abonnement**, choisir une offre.
3. Utiliser la carte de test Stripe `4242 4242 4242 4242`, une date future et un CVC quelconque.
4. Vérifier le retour dans Piloz, le statut actif, les quatre derniers chiffres et la facture dans l'historique.
5. Ouvrir le portail Stripe depuis Piloz et vérifier le changement de carte et la résiliation.
6. Tester un échec de paiement avec une carte de test prévue à cet effet dans la documentation Stripe.
7. Contrôler dans Stripe que les événements du webhook ont reçu une réponse HTTP 200.

Le passage en production consiste ensuite à remplacer les deux secrets par leurs valeurs du mode réel, créer le webhook réel et effectuer un paiement réel de faible montant avant ouverture aux clients.

## Références officielles

- Stripe Checkout : https://docs.stripe.com/api/checkout/sessions/create
- Portail client Stripe : https://docs.stripe.com/customer-management/integrate-customer-portal
- Signature des webhooks : https://docs.stripe.com/webhooks/signature
- Événements d'abonnement : https://docs.stripe.com/billing/subscriptions/webhooks
- Secrets des Edge Functions Supabase : https://supabase.com/docs/guides/functions/secrets
- Déploiement des Edge Functions : https://supabase.com/docs/guides/functions/deploy
