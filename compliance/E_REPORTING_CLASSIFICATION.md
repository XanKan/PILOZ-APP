# Préclassification e-invoicing et e-reporting

`classifyTransactionForFrenchEInvoicing(context)` fournit une **préclassification**, pas une décision fiscale définitive. Chaque résultat comprend la règle, les données manquantes, une justification, `externalValidationRequired=true` et `transmitted=false`.

Résultats techniques : `e_invoice`, `e_reporting_transaction`, `e_reporting_payment`, `out_of_scope`, `to_verify`.

Règles préliminaires version `fr-preclassification-v1` :

- données de catégorie client, pays ou nature d'opération manquantes : `to_verify` ;
- secteur public : `to_verify` jusqu'à validation du routage applicable ;
- paiement d'une prestation : présélection `e_reporting_payment` ;
- B2B France : présélection `e_invoice` ;
- B2C ou client hors France : présélection `e_reporting_transaction` ;
- tout autre cas : `to_verify`.

Ces règles doivent être validées par un fiscaliste et confrontées aux textes officiels, au calendrier d'entrée en vigueur, aux cas XP Z12-014 et à la plateforme retenue. Rien n'est transmis automatiquement.
