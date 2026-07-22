# Architecture du connecteur de plateforme agréée

## État

Le connecteur de production est **non configuré**. Piloz n'est pas une plateforme agréée et aucune donnée n'est envoyée à l'administration. L'unique adaptateur exécutable livré dans le dépôt est `PILOZ_SANDBOX`, affiché et journalisé comme `Simulation` avec `external_network=false` et `sent_to_administration=false`.

L'API réelle devra être développée à partir de l'édition applicable de XP Z12-013 et de la documentation contractuelle de la plateforme choisie. Ces éléments ne sont pas présents dans le dépôt.

## Contrat technique

`AccreditedPlatformConnector` couvre configuration, résolution destinataire, émission/réception, statuts, e-reporting, paiements, pièces, webhooks, vérification de signature, reprise et annulation. Les credentials sont désignés uniquement par une référence de secret serveur ; ils ne figurent jamais dans les tables ou le navigateur.

Les transmissions utilisent une clé d'idempotence unique par entreprise et connecteur. Une projection conserve l'état opérationnel ; `platform_transmission_events` conserve chaque étape sans UPDATE/DELETE. Les retries utilisent un backoff borné de 5 secondes à 1 heure. Après épuisement, une entrée de dead-letter doit être ouverte et reprise par une opération serveur contrôlée.

## Statuts

Les statuts commercial/comptable de `documents`, le statut de facture électronique et le statut de transmission sont distincts. Une simulation ne fait pas évoluer le statut électronique vers `transmitted`.

La machine de cycle électronique est versionnée `draft-v1-external-validation-required`. Sa liste et ses transitions doivent être confrontées aux éditions applicables de XP Z12-012/014 avant activation.

## Webhooks

L'abstraction fournit une vérification HMAC-SHA-256 à comparaison constante. Le futur endpoint réel devra charger le secret depuis le coffre, vérifier la signature avant analyse, conserver le corps original dans un bucket privé, dédupliquer `external_event_id`, limiter la taille et journaliser sans données sensibles. Aucun webhook sandbox fictif n'est présenté comme valide.

## Production bloquée

Le schéma interdit `production_enabled=true` sans connecteur de type plateforme agréée, environnement production, secret référencé, statut actif et absence de simulation. Cette condition de données ne suffit pas : l'Edge Function refuse encore explicitement l'action production tant qu'un adaptateur réel n'a pas été implémenté et validé.
