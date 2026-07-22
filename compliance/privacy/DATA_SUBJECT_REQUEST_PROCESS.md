# Procédure des demandes de droits

## Objet

Cette procédure couvre accès, rectification, effacement, limitation, portabilité et opposition. Elle doit être adaptée par le responsable de traitement avant mise en production.

## Traitement

1. Enregistrer la demande dans `data_subject_requests` sans copier inutilement une pièce d’identité.
2. Vérifier l’identité par un moyen proportionné et consigner la date, jamais le secret utilisé.
3. Fixer l’échéance initiale à un mois après réception; documenter toute prolongation légalement admise.
4. Rechercher les données dans les catégories de `DATA_MAP.md` avec l’identifiant de l’entreprise.
5. Pour chaque catégorie, créer une décision dans `data_subject_request_items`: export, rectification, suppression, anonymisation, conservation, limitation ou absence.
6. Vérifier les obligations de conservation, litiges et archives fiscales avant toute suppression. Une donnée légalement figée est conservée avec accès limité; la raison est documentée.
7. Faire valider les décisions sensibles par une personne habilitée.
8. Produire une réponse intelligible et sécurisée, puis consigner la date de clôture et l’empreinte de la preuve transmise.

## Règles techniques

- Ne jamais contourner les contraintes d’inaltérabilité d’une facture, d’un paiement ou du journal fiscal.
- L’effacement d’une fiche reliée à une preuve légale doit privilégier la minimisation ou l’anonymisation compatible avec l’obligation de conservation.
- Les exports sont générés côté serveur, limités à l’entreprise concernée et ne contiennent aucun secret technique.
- Une suppression en masse exige sauvegarde vérifiée, prévisualisation, double contrôle et journalisation.
- Toute erreur, refus ou conservation doit être motivé; aucune décision automatique n’est présentée comme définitive.

## Responsabilités à nommer

- réception et vérification d’identité;
- recherche et export;
- validation juridique des exceptions;
- exécution technique;
- réponse au demandeur;
- contrôle de clôture.

