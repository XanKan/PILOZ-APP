# Rapport de phase 2 — documents fiscaux

Date : 22 juillet 2026

## Livré

- configuration fiscale par entreprise, désactivée par défaut ;
- marqueur explicite `legacy_unsecured` pour les données historiques et les documents produits avant activation ;
- manifeste de versions sur les documents finalisés ;
- registre immuable des attributions de numéros, sans backfill rétroactif ;
- moteur financier `financial-v1` côté PostgreSQL et aperçu BigInt côté navigateur ;
- validateur central et résolution centrale des codes de mentions ;
- finalisation republiée avec recalcul, validation, numéro, versions, snapshot et tâche PDF dans une transaction ;
- garde frontend empêchant le fallback CRUD des documents fiscaux lorsque les RPC sont absentes.

## Tests

- toutes les migrations chargées avec PGlite ;
- création/modification devis, conversion, verrouillage, facture brouillon et finalisation : réussi ;
- attribution traçable et immuable : réussi ;
- validation centrale et manifeste de versions : réussi ;
- calculs BigInt navigateur : 8/8 ;
- calculs commerciaux existants : 16/16 ;
- routes/éditeurs : 42/42.

## Limites

- aucune activation de production automatique ;
- aucune donnée historique n'est signée rétroactivement ;
- le commit de déploiement restera `not-recorded` tant que le processus de release ne l'injecte pas ;
- les textes exacts des mentions conditionnelles nécessitent une validation juridique ;
- la concurrence réelle doit aussi être testée sur un projet Supabase de recette.
