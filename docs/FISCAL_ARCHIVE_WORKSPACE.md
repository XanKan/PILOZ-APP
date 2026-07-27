# Archives fiscales dans Piloz

## Périmètre

La rubrique `Comptabilité > Archives fiscales` est disponible pour toutes les entreprises Piloz. Elle n’ajoute aucune étape à l’onboarding. Sa création est réservée aux propriétaires et administrateurs de l’entreprise ; sa visibilité dans la navigation suit le droit de gestion des exports comptables.

Une archive fiscale Piloz est un paquet JSON autonome qui contient :

- le manifeste figé de la période ;
- les données des factures et avoirs définitifs ;
- les PDF originaux encodés et leurs empreintes SHA-256 ;
- les règlements, clôtures et événements de piste d’audit concernés ;
- l’empreinte globale, la chaîne avec l’archive précédente et la signature AWS KMS.

Le paquet est limité à 50 Mo. Pour une entreprise très active, il faut utiliser des périodes mensuelles ou plus courtes.

## Parcours utilisateur

1. Piloz propose le mois civil précédent.
2. L’utilisateur peut choisir une autre période entièrement terminée.
3. `Générer l’archive` appelle la fonction SQL `create_fiscal_archive` avec `target_allow_incomplete=false`.
4. Piloz contrôle la chaîne fiscale et exige tous les PDF définitifs.
5. L’Edge Function `export-fiscal-archive` recalcule les empreintes, signe l’empreinte globale avec AWS KMS et vérifie immédiatement la signature.
6. La signature et l’export sont inscrits dans des registres immuables.
7. Le fichier `<numero-archive>.json` est téléchargé dans le navigateur.

Les boutons `Vérifier` et `Télécharger` repassent toujours par le contrôle d’intégrité et la vérification KMS. Un échec bloque l’opération ; aucune validation visuelle fictive n’est affichée.

## Quand générer une archive

Le rythme mensuel est recommandé : il produit des fichiers raisonnables et facilite un contrôle. Une archive est également utile :

- avant de migrer Piloz ou le logiciel comptable ;
- avant ou après une clôture importante ;
- avant de résilier un service ;
- lorsqu’un expert-comptable ou un contrôle demande une copie autonome de la piste d’audit ;
- avant une opération technique majeure touchant l’hébergement ou les documents.

## Conservation

Le fichier téléchargé doit être conservé dans un emplacement durable, sauvegardé et distinct de Piloz. L’archive aide à démontrer l’intégrité et la traçabilité, mais elle ne remplace pas :

- le logiciel comptable et son FEC ;
- la conservation légale des factures et justificatifs ;
- une plateforme agréée pour la facturation électronique ;
- une certification réglementaire lorsqu’elle est applicable à l’activité de l’entreprise.

La vérification future nécessite de conserver les métadonnées de la clé KMS et de ne pas détruire une ancienne clé tant que des archives signées avec elle doivent rester vérifiables.
