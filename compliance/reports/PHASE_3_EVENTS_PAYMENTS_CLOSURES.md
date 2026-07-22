# Rapport de phase 3 — événements, encaissements et clôtures

Date : 22 juillet 2026

## Livré

- journal `fiscal_events` append-only, séquence et tête isolées par entreprise ;
- chaînage SHA-256 et vérificateur complet ;
- événement automatique lors de la finalisation d'une facture/avoir et lors des changements de statut ultérieurs ;
- registre d'encaissements append-only sur `payments` ;
- correction d'un paiement par nouvelle écriture négative, sans mutation de l'original ;
- recalcul du solde et des échéanciers depuis la somme des écritures ;
- clôtures journalières, mensuelles et annuelles immuables, avec cumuls, ventilations, empreintes et chaînage ;
- abstraction de signature qui échoue explicitement sans KMS.

## Honnêteté des états

Les événements sont chaînés mais non signés. Les clôtures portent `unsigned`. La ventilation TVA des clôtures est marquée `not_computed_requires_validation` plutôt que d'être approximée. Le niveau exact des clôtures reste à valider avec le référentiel NF 525 officiel.

## Validation encore nécessaire

- KMS/HSM et politique de clés ;
- test de charge et concurrence sur Supabase de recette ;
- applicabilité et format des clôtures avec l'organisme certificateur ;
- revue du registre d'encaissements et des cas trop-perçu/remboursement/rejet/chargeback.
