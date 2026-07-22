# Format d'archive fiscale PILOZ

## Statut

Le format `piloz-fiscal-archive` version `1.0` est un format technique interne ouvert (JSON et PDF). Il ne constitue pas une certification NF 525, NF 203 ou AFNOR. Le choix final du format, de la signature et de la durée de conservation doit être validé juridiquement et par l'organisme certificateur.

## Contenu

Une archive contient un manifeste figé, un export JSON des snapshots publics, encaissements, corrections, clôtures, événements et rôles pertinents, ainsi que chaque PDF final référencé par son chemin et son SHA-256. Les données historiques restent marquées `legacy_unsecured` ; aucune preuve rétroactive n'est inventée.

Chaque élément porte : chemin relatif sûr, type MIME, catégorie, état, taille lorsque connue, méthode de canonicalisation et SHA-256. Le manifeste et l'archive sont chaînés avec l'archive précédente de l'entreprise.

## Canonicalisation

- objets JSON issus de PostgreSQL : représentation `jsonb::text`, identifiée `postgres-jsonb-text-v1` ;
- PDF : octets bruts, identifiés `raw-bytes` ;
- hash : SHA-256 en hexadécimal minuscule.

Le fichier structuré embarque, pour chaque événement, le matériau exact utilisé par PostgreSQL pour calculer `event_hash`. Le vérificateur peut ainsi contrôler la chaîne hors de l'application sans reproduire les règles de formatage temporel de PostgreSQL.

## Signature

Les champs de signature restent vides et le statut reste `unsigned` tant qu'un KMS, une politique de rotation et les clés publiques de vérification ne sont pas configurés. Une archive non signée peut être intègre au sens des empreintes, mais ne doit pas être présentée comme une archive fiscale signée.

En mode fiscal `production`, la fonction SQL bloque actuellement la création : l'intégration effective du fournisseur de signature serveur est un prérequis volontaire.

## Vérification hors application

Commande :

```powershell
node scripts/verify-fiscal-archive.mjs C:\chemin\archive.json --report=C:\chemin\rapport.json
```

Le code de sortie vaut `0` si les empreintes et la chaîne sont intactes, même si l'absence de signature est signalée séparément. Il vaut `2` en cas d'altération, de fichier manquant, de format illisible ou de signature invalide.

## Limites actuelles

- export JSON limité à 50 Mo par l'Edge Function ; fractionner la période au-delà ;
- pas de signature tant que le KMS n'est pas choisi et validé ;
- pas de qualification probatoire externe ;
- pas d'archivage à valeur probante auprès d'un tiers ;
- conservation Storage et sauvegardes à activer et vérifier dans le projet Supabase réel.
