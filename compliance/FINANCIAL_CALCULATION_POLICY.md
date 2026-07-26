# Politique de calcul financier — version `financial-v2-deposit-deduction`

## Autorité

Le calcul PostgreSQL exécuté par `recalculate_document_amounts_v1` est autoritaire lors de la finalisation. Le calcul JavaScript sert à l'aperçu et utilise des entiers `BigInt` ; les valeurs envoyées par le navigateur ne sont jamais considérées comme une preuve du total final.

## Précision et arrondis

- quantités et prix unitaires : quatre décimales en entrée ;
- taux de remise et de TVA : deux décimales ;
- montants stockés : `numeric(15,2)` en base et centimes entiers dans le moteur JavaScript ;
- montant HT d'une ligne : quantité × prix × (1 − remise), arrondi à deux décimales ;
- TVA d'une ligne : HT arrondi × taux, arrondie à deux décimales ;
- remise globale : appliquée aux sommes HT et TVA, puis chaque somme est arrondie à deux décimales ;
- TTC : HT arrondi + TVA arrondie ;
- mode PostgreSQL utilisé : `round(numeric, 2)`, soit arrondi au plus proche avec les demis éloignés de zéro.

## Déduction des acomptes

- les totaux HT, TVA et TTC bruts sont conservés dans les métadonnées du document ;
- l’acompte déductible provient uniquement de factures d’acompte finalisées liées au même devis ;
- les déductions déjà figées sur les situations précédentes sont retranchées du solde disponible ;
- la méthode peut être complète, proportionnelle à l’avancement cumulé ou limitée à un montant TTC fixe ;
- la déduction ne peut dépasser ni le solde d’acompte disponible ni le montant brut de la facture ;
- le total TTC stocké et exigible est le total brut diminué de la déduction ;
- le serveur PostgreSQL recalcule ces montants avant toute finalisation et les fige dans l’instantané légal.

## Cohérence

L'instantané final conserve la version de calcul et les paramètres d'arrondi. Le PDF et les futurs formats structurés doivent lire l'instantané final, pas recalculer les montants. Toute évolution crée une nouvelle version ; elle ne modifie pas les documents finalisés antérieurs.

## Limites à faire valider

Les règles sectorielles, devises sans deux décimales, conversions de devises, ventilation d'une remise globale par taux et tolérances des profils électroniques doivent être validées juridiquement et contre les artefacts officiels avant activation de production.
