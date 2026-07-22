# Rapport de phase 6 — plateforme et e-reporting

Date : 22 juillet 2026

## Livré

- interface générique `AccreditedPlatformConnector` couvrant les opérations demandées ;
- sandbox local explicitement simulé et sans réseau externe ;
- clés d'idempotence et protection anti-doublon ;
- projections de transmissions, événements append-only, webhooks et dead-letter queue ;
- backoff contrôlé et vérification HMAC disponibles pour le futur adaptateur ;
- cycle électronique séparé du cycle commercial/comptable ;
- moteur de préclassification e-invoice, e-reporting transaction et paiement ;
- Edge Function refusant explicitement la production non configurée.

## Tests

- migrations complètes : réussite ;
- création sandbox : réussite ;
- simulation : statut utilisateur `Simulation`, aucun envoi externe ;
- rejeu avec même clé : même transmission, `idempotent=true` ;
- facture non marquée `transmitted` après simulation ;
- B2B France : présélection `e_invoice`, validation externe requise ;
- navigateur : 15/15 contrôles du domaine électronique réussis.

## Restant

- sélectionner et contractualiser une plateforme agréée réelle ;
- obtenir ses spécifications/API et les textes applicables XP Z12-013/014 ;
- implémenter OAuth/mTLS, résolution annuaire, webhooks signés, retries et DLQ dans l'adaptateur réel ;
- valider juridiquement le moteur de classification et le cycle de statuts ;
- réaliser les tests d'interopérabilité, sandbox fournisseur puis homologation contractuelle ;
- aucune transmission réelle, aucun accusé réel et aucune preuve de conformité réglementaire à ce stade.
