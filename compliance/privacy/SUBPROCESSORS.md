# Registre préparatoire des sous-traitants

État au 22 juillet 2026 : inventaire technique, à compléter avec les contrats, régions, finalités exactes et mécanismes de transfert du déploiement réel.

| Fournisseur / catégorie | Usage observé ou prévu | Données potentielles | Statut de validation |
|---|---|---|---|
| Supabase | authentification, PostgreSQL, Storage, Edge Functions | comptes, données métier, documents | fournisseur utilisé; projet, région, DPA, sauvegardes et accès opérateur à documenter |
| GitHub / GitHub Pages | dépôt, CI, hébergement statique | code et artefacts publics; aucune donnée métier prévue | utilisé; vérifier journaux CI, permissions et absence de secret |
| Plateforme de dématérialisation partenaire | factures électroniques, statuts, e-reporting | factures, clients, paiements déclarables | aucun connecteur de production configuré; fournisseur et contrat à sélectionner |
| Fournisseur KMS / signature | signature ou scellement des preuves | empreintes et métadonnées techniques | non configuré; fournisseur et politique de clés à sélectionner |
| Messagerie transactionnelle | envoi de factures et relances | destinataires, objets, pièces jointes | configuration réelle à inventorier avant activation |
| Services de recherche d’entreprise/adresse | autocomplétion | requêtes de société et d’adresse | endpoints et conditions réelles à vérifier |

## Contrôle d’entrée

Avant d’activer un nouveau fournisseur: finalité, minimisation, localisation, sous-traitants ultérieurs, durée, suppression, sécurité, notification d’incident, réversibilité, transfert hors EEE et preuve contractuelle doivent être renseignés. Aucun statut positif dans l’application ne doit être déduit de ce fichier seul.

