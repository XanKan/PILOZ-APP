# Registre initial des risques de conformité

Échelle : impact et probabilité de 1 à 5 ; score = impact × probabilité. Ce registre est un outil interne à réviser à chaque changement fiscal.

| ID | Risque | Cause observée | Impact | Prob. | Score | Traitement prévu | État |
|---|---|---|---:|---:|---:|---|---|
| R-001 | Modification directe de données fiscales depuis le navigateur | Fallbacks CRUD lorsque les RPC sont absentes | 5 | 3 | 15 | Retirer les fallbacks fiscaux et révoquer les privilèges de table après activation | Ouvert critique |
| R-002 | Rupture ou doublon de séquence | Paramètres de séquence modifiables par le frontend | 5 | 3 | 15 | Configuration contrôlée avant activation, attribution RPC et journal dédié | Ouvert critique |
| R-003 | Altération non détectée | Pas de chaîne fiscale append-only | 5 | 4 | 20 | Chaînage SHA-256 canonique et vérification complète | Ouvert critique |
| R-004 | Fausse preuve cryptographique | Aucun KMS/signataire configuré | 5 | 4 | 20 | Interface de signature, état `non_configured`, blocage des allégations | Ouvert critique |
| R-005 | Paiement original altéré | Annulation par mutation du statut du paiement | 5 | 4 | 20 | Registre append-only et événement inverse | Ouvert critique |
| R-006 | Archive non probante | Aucun manifeste ni vérification hors application | 5 | 4 | 20 | Archive ouverte, empreintes, signature KMS et vérificateur | Ouvert critique |
| R-007 | Transmission électronique invalide | Aucun artefact XSD/Schematron officiel fourni | 5 | 4 | 20 | Refuser le statut validé/transmis sans artefacts officiels | Ouvert critique |
| R-008 | Mauvaise qualification e-reporting | Contexte client/opération incomplet | 5 | 3 | 15 | Moteur explicable retournant `à vérifier` si données manquantes | Ouvert |
| R-009 | Fuite inter-entreprises | RLS de production non introspectées | 5 | 2 | 10 | Tests croisés sur environnement Supabase et revue des policies | À vérifier en production |
| R-010 | Perte de données/preuves | Sauvegardes Supabase non confirmées | 5 | 3 | 15 | Configurer sauvegardes DB/Storage, export et exercice de restauration | À vérifier manuellement |
| R-011 | Rétroactivité trompeuse | Tentation de signer les anciennes factures | 5 | 2 | 10 | Marquage `legacy_unsecured`, aucune signature rétroactive | Traitement planifié |
| R-012 | Mauvaises mentions fiscales | Règles dispersées et conditionnelles incomplètes | 5 | 4 | 20 | Validateur central et revue juridique | Ouvert critique |
| R-013 | Calcul incohérent écran/PDF/XML | Calculs JS `Number` et SQL numeric séparés | 5 | 3 | 15 | Montants mineurs/decimal centralisés, serveur autoritaire | Ouvert critique |
| R-014 | Droit d'accès excessif | Rôles limités à owner/admin/member | 4 | 4 | 16 | RBAC explicite et journal des permissions sensibles | Ouvert critique |
| R-015 | Allégation commerciale non prouvée | Certification future confondue avec code livré | 5 | 2 | 10 | Statuts honnêtes et table de certificats vide par défaut | Sous contrôle |
| R-016 | Purge contraire à une obligation | Pas de politique par finalité | 5 | 3 | 15 | Matrice de conservation et blocage des données fiscales | Ouvert |
| R-017 | Version non reproductible | Documents sans toutes les versions moteur | 4 | 4 | 16 | Snapshot des versions à la finalisation | Ouvert |
| R-018 | Migration partielle en production | Documentation de déploiement arrêtée à la migration 012 | 5 | 3 | 15 | Inventaire automatique et contrôle de version du schéma | Ouvert critique |

## Acceptation des risques

Aucun risque critique fiscal ne peut être accepté implicitement. Toute acceptation temporaire doit indiquer un propriétaire, une échéance, un périmètre, des contrôles compensatoires et une approbation écrite. La présence de code ne vaut ni validation juridique ni certification.
