# Plan de management de la qualité

Statut : préparation interne à un futur audit ; aucune certification NF 203 n'est revendiquée.

## Gouvernance

Le responsable produit approuve les exigences et releases. Le responsable technique garantit revue, tests, migration et retour arrière. Le responsable conformité tient la matrice, les risques et preuves. Le DPO traite la protection des données. Les rôles peuvent être cumulés, mais l'auteur d'une modification fiscale ne doit pas être son seul approbateur.

## Cycle

Une demande est identifiée, classée, reliée à une exigence, analysée en risque, développée, revue, testée puis livrée selon `RELEASE_PROCESS.md`. Une modification fiscale met aussi à jour `FISCAL_CHANGE_LOG.md`, migrations, tests, preuves et limites. Un échec critique bloque la release.

## Indicateurs

- exigences couvertes par code/test/preuve ;
- tests réussis et régressions ;
- vulnérabilités ouvertes par sévérité et délai ;
- incidents et temps de restauration ;
- restaurations réellement testées ;
- anomalies de chaîne, séquence, archive et transmission ;
- demandes support et RGPD hors délai.

## Revues

Revue par release et revue trimestrielle du registre des risques, dépendances, sauvegardes, accès, incidents et exigences externes. Les procès-verbaux, responsables et actions doivent être conservés. Ce document doit être approuvé formellement avant audit.
