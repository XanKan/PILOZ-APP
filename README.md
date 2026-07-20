# PILOZ-APP

Piloz est une application SaaS de gestion commerciale en thème clair, publiée sur `https://app.piloz.fr`. Le front statique reste compatible GitHub Pages ; Supabase fournit l’authentification, PostgreSQL, les politiques RLS, le stockage privé, les RPC transactionnelles et les fonctions Edge.

## Modules

- tableau de bord personnalisable, comparaisons N/N-1 et indicateurs issus des données réelles ;
- suivi commercial : prospects, opportunités, pipeline, activités et relances ;
- ventes : clients particuliers/professionnels, catalogue, devis, factures, acomptes, avoirs, paiements et échéances ;
- achats : fournisseurs, commandes, réceptions et factures fournisseurs ;
- stock : disponibilité calculée depuis les mouvements, réservations, inventaires, entrepôts et emplacements ;
- modèles documentaires versionnés, modes visuel/code/aperçu et HTML/CSS assainis ;
- paramètres d’entreprise, documents, TVA, banque, stock, pipeline, utilisateurs et permissions.

## Architecture

- `index.html` : point d’entrée et compatibilité historique ;
- `assets/css/modern-erp.css` : variables, composants, vues et responsive de la nouvelle interface ;
- `assets/js/modules/erp/erp-app.js` : flux ERP existants et éditeurs ;
- `assets/js/modules/erp/erp-modern.js` : navigation, tableau de bord, CRM et listes commerciales modernes ;
- `assets/js/api/erp-api.js` : accès Supabase centralisé et erreurs françaises ;
- `supabase/migrations/` : migrations additives, non destructives et durcissement des privilèges RPC ;
- `supabase/functions/` : recherches officielles, confirmations, documents et modèles ;
- `tests/` et `supabase/tests/` : calculs, rendu des routes et contrôles RLS.

## Documentation

- `docs/AUDIT_PHASE1.md` : audit initial et architecture ;
- `docs/ACCEPTANCE.md` : couverture des 47 contrôles demandés ;
- `docs/DEPLOYMENT.md` : déploiement et contrôles de production.

Le navigateur ne doit contenir que la clé publique Supabase. Les clés `service_role`, Resend et Twilio restent exclusivement dans les secrets Supabase.
