# Modèle de données Activités

## Tables centrales

### `activities`

Contient l’identité, le type, le titre, la description, les dates, la durée, le statut, la priorité, le responsable, l’équipe, la confidentialité, l’origine, le lieu, la visioconférence, le compte rendu, la prochaine étape et les marqueurs d’archivage/annulation. Les colonnes historiques (`client_id`, `opportunity_id`, `document_id`) restent alimentées pour compatibilité.

### `activity_types`

Types configurables par entreprise : libellé, icône, couleur, catégorie, durée/statut/rappel par défaut, résultat obligatoire, schéma de champs, position et activation.

### `activity_outcomes`

Résultats configurables par type, par exemple joint, sans réponse, qualifié ou à relancer.

## Tables associées

- `crm_activity_links` : relations métier multiples ;
- `crm_activity_participants` : participants internes et externes ;
- `activity_reminders` : rappels et état de livraison ;
- `activity_checklist_items` : étapes de préparation ;
- `activity_attachments` : métadonnées des fichiers stockés ;
- `activity_events` : journal append-only ;
- `activity_sync_links` : correspondance et statut des agendas externes ;
- `activity_saved_filters` : filtres personnels ou partagés.

## Valeurs structurées

Statuts : brouillon, à faire, planifiée, en cours, terminée, annulée, manquée, reportée.  
Priorités : basse, normale, haute, urgente.  
Confidentialité : standard, entreprise, équipe, privée.  
Origines : manuelle, Gmail, Outlook, Google Agenda, Outlook Calendar, automatisation, conversion, API, Pilo, système.

## Cycle de vie

Une activité est créée, modifiée, terminée, reportée, annulée ou archivée. Elle n’est pas supprimée physiquement. La clôture peut créer une activité fille, reliée par `parent_activity_id` et `next_activity_id`.

