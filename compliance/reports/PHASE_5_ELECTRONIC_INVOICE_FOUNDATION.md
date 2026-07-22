# Rapport de phase 5 — modèle canonique et formats électroniques

Date : 22 juillet 2026

## Livré

- modèle canonique indépendant de l'interface, disponible côté navigateur et PostgreSQL ;
- conservation append-only du modèle, de son empreinte et de son rapport de validation ;
- champs contextuels entreprise, client et document nécessaires à la préparation de la réforme ;
- registre de profils officiels vide par défaut ;
- interfaces d'adaptateurs UBL, CII et Factur-X côté serveur ;
- stockage prévu pour fichiers originaux, PDF, profils et rapports ;
- blocage testé de chaque export normatif lorsqu'aucun profil officiel n'est installé.

## Tests

- modèle navigateur : 11/11 contrôles réussis ;
- modèle serveur créé depuis une facture finalisée : réussite ;
- conservation de la ligne et du snapshot : réussite ;
- rapport de règles métier : valide dans le jeu d'essai ;
- tentative UBL sans profil : bloquée avec `official_profile_not_configured` ;
- migrations complètes via PGlite : réussite.

## Non livré volontairement

Aucun XML UBL/CII et aucun PDF Factur-X approximatif. Aucun XSD ou Schematron non sourcé n'a été inventé. Les tests 35 à 39 du plan global restent non exécutables tant que les artefacts officiels, leur version et leur droit d'utilisation ne sont pas fournis.

## Actions externes

- acquérir/obtenir légalement les spécifications et jeux de validation applicables ;
- choisir les profils et cas d'usage avec la plateforme agréée retenue ;
- valider le mapping canonique avec un spécialiste ;
- installer les artefacts avec leurs empreintes ;
- faire valider des fichiers valides et invalides par les outils officiels.
