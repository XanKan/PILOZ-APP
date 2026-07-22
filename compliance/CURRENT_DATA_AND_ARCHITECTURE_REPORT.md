# Rapport des données et de l'architecture existantes

## Inventaire

- 38 migrations additives datées du 20 au 22 juillet 2026.
- Tables principales : entreprises, membres, paramètres, clients, fournisseurs, catalogue, documents, lignes, modèles, instantanés, tâches PDF, liens, paiements, échéanciers, CRM, achats, stock et journaux d'activité.
- 8 Edge Functions : recherche entreprise/adresse, confirmations de contact, sauvegarde de modèle, envoi e-mail et génération PDF.
- Frontend statique GitHub Pages ; appels REST/RPC Supabase via `assets/js/api/erp-api.js`.
- Stockage privé prévu pour logos, pièces et PDF avec URLs signées.

## Données historiques

Les migrations ne fournissent pas de preuve que les factures historiques ont été finalisées sous un mécanisme fiscal sécurisé. Elles doivent être classées comme données historiques antérieures à l'activation, sans signature rétroactive. Un rapport quantitatif de production devra relever au minimum : documents par type/statut, numéros manquants/dupliqués, ruptures de séquence, factures finalisées sans snapshot/PDF/hash, paiements croisés, lignes sans `company_id` cohérent et fichiers manquants.

## Frontières cibles

1. Domaine commercial modifiable : devis et brouillons.
2. Domaine fiscal serveur : finalisation, avoirs, paiements, clôtures et événements.
3. Preuves : snapshots, PDF finaux, données structurées, hashes, signatures et versions.
4. Archives : manifestes et objets figés vérifiables hors application.
5. E-invoicing : modèle canonique, validateurs et transmissions distincts.

## Dette de déploiement

`docs/DEPLOYMENT.md` ne liste que les migrations jusqu'à `202607210012` alors que le dépôt en contient 38. L'état de production doit être contrôlé avant activation ; une interface affichant la version de schéma appliquée est nécessaire.

## Décision

Les nouvelles structures seront additives et désactivées par défaut. Les anciens flux restent disponibles uniquement tant que le moteur fiscal n'est pas activé. Après activation, les écritures sensibles devront passer exclusivement par des RPC/Edge Functions contrôlées et la base devra refuser les anciens chemins.
