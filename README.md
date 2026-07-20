# PILOZ-APP

Application ERP de gestion commerciale compatible GitHub Pages, avec Supabase pour l’authentification, PostgreSQL, les politiques RLS, le stockage et les fonctions serveur.

Modules présents : onboarding professionnel, clients, fournisseurs, catalogue, devis, factures, commandes clients, modèles versionnés, stock par mouvements, réservations, livraisons, inventaires, achats, réceptions, coût moyen et rapports de marge.

Documentation :

- `docs/AUDIT_PHASE1.md` : audit initial, risques, architecture et plan de migration ;
- `docs/ACCEPTANCE.md` : couverture et statut des 38 scénarios obligatoires ;
- `docs/DEPLOYMENT.md` : ordre des migrations, secrets et contrôles de recette.

Les fichiers du dépôt ne déploient rien automatiquement. Aucun secret serveur ne doit être placé dans les assets publics.
