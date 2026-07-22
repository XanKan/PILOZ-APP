# Cycle de développement sécurisé

## Concevoir

Définir actifs, locataires, flux, données personnelles/fiscales, abus, exigences RLS et secrets. Les opérations fiscales sont des RPC serveur, pas du CRUD navigateur. Toute dépendance externe a une analyse de confiance et de disponibilité.

## Développer

Branches/commits traçables, revue obligatoire, paramètres validés, requêtes paramétrées, sorties échappées, fonctions `SECURITY DEFINER` avec `search_path`, privilèges révoqués puis accordés explicitement. Jamais de clé privée/service role dans le frontend ou Git.

## Vérifier

Tests domaine/intégration/interface, migrations sur données existantes, RLS inter-entreprises, SAST/revue, dépendances, secrets, CSP/XSS, idempotence, charge et restauration. Les findings sont suivis selon `VULNERABILITY_MANAGEMENT.md`.

## Livrer et exploiter

Release signée/attestée lorsque l'infrastructure sera disponible, séparation test/production, secrets dans le coffre, moindre privilège, logs minimisés, alertes, rotation, sauvegardes et procédure incident. Les builds doivent être reproductibles ; le commit et les versions sont enregistrés dans les preuves fiscales.
