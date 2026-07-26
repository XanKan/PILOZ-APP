# Rapport de migration CRM

## Principe

Les migrations `202607260077_crm_command_center.sql`, `202607260078_crm_enterprise_operations.sql` et `202607260079_crm_enterprise_workspace.sql` sont strictement additives. Elles ne suppriment aucune table, aucun document, aucun prospect, aucune opportunité et aucun historique. Tant qu'elles ne sont pas appliquées à Supabase, les fonctions serveur correspondantes ne doivent pas être annoncées comme actives.

## Réutilisation des données

- Les prospects restent dans `clients` avec `relationship_type='prospect'`.
- La conversion change le type de relation sur la même fiche ; aucun second tiers n'est créé.
- Les contacts restent dans `client_contacts`.
- Les opportunités restent dans `opportunities` et conservent leurs identifiants.
- Les étapes historiques restent dans `pipeline_stages`.
- Les activités restent dans `activities`.
- Les devis, factures, avoirs, règlements, pièces jointes et historiques ne sont pas copiés.

## Nouvelles structures

- `crm_pipelines` : pipelines multiples configurables ;
- `crm_sources` et `crm_loss_reasons` : référentiels configurables ;
- `crm_opportunity_products` : catalogue envisagé dans une affaire ;
- `crm_activity_participants` et `crm_activity_links` : participants et liens multiples ;
- `crm_notes` : notes épinglables ;
- `crm_tags` et `crm_tag_assignments` : étiquettes transversales ;
- `crm_custom_fields` et `crm_custom_field_values` : propriétés personnalisées ;
- `crm_automation_rules` et `crm_automation_runs` : règles et journal ;
- `crm_sequences`, `crm_sequence_steps`, `crm_sequence_enrollments` : séquences commerciales ;
- `crm_saved_views` et `crm_segments` : vues et segments persistés ;
- `crm_score_rules` et `crm_score_history` : score explicable ;
- `crm_timeline_events` : chronologie unifiée append-only ;
- `company_dashboard_defaults` : disposition de référence par entreprise et rôle.

## Opérations atomiques ajoutées

- administration et duplication de plusieurs pipelines, étapes et ordre des colonnes ;
- mise à jour atomique des prospects et opportunités ;
- import CSV contrôlé, anti-doublon et fusion sans perte d'historique ;
- recherche globale indexée sur tiers, contacts, opportunités, documents et activités ;
- replanification d'une activité depuis l'agenda avec événement de timeline ;
- vues personnelles ou partagées persistées dans `crm_saved_views` ;
- traitement d’un e-mail réellement synchronisé et rattachement à un tiers ou une opportunité.
- journal des automatisations et relance explicite d’une exécution échouée ; seules les actions transactionnelles sont rejouées et un e-mail reste bloqué sans confirmation du connecteur.

`external_mail_links` reçoit uniquement des métadonnées de traitement (`sender`, `preview`, `treatment_status`, `assigned_user_id`). Les secrets OAuth restent dans la table réservée au service, jamais dans le navigateur.

## Colonnes additives

`pipeline_stages` reçoit le pipeline, le type, le délai conseillé et les règles d'entrée/sortie. `opportunities` reçoit le pipeline, l'étape relationnelle, la source, le contact, les catégories de prévision, le score, les dates de gain/perte et les motifs. `activities` reçoit le contact, la localisation, les données de calendrier et les rappels structurés.

## Reprise automatique

Pour chaque entreprise existante, la migration :

1. crée un pipeline `Ventes principales` si aucun pipeline n'existe ;
2. rattache les étapes existantes au pipeline par défaut ;
3. rattache les opportunités à ce pipeline et à l'étape correspondant à leur slug ;
4. crée les sources et raisons de perte initiales sans écraser les valeurs existantes ;
5. conserve toutes les dates et tous les identifiants existants.

La migration n'invente aucun événement antérieur. La timeline commence avec les événements réellement observés après déploiement ; l'historique d'étapes existant reste consultable. La boîte CRM reste vide sans connecteur réellement actif et aucun envoi n'est déclaré réussi sans réponse du fournisseur.

## Droits et isolation

- toutes les requêtes dérivent l'entreprise de `auth.uid()` ;
- les rôles de lecture seule ne peuvent pas déplacer, modifier ou rattacher des données ;
- les écritures métier exigent une permission `manage_customer`, `manage_opportunity` ou `manage_reminder` ;
- les référentiels partagés (pipelines, sources, règles, séquences) restent réservés aux propriétaires et administrateurs ;
- une boîte personnelle n'est lisible et modifiable que par son propriétaire ; une boîte partagée exige `extensions_manage_global`.

## Retour arrière

Le frontend conserve une stratégie de repli sur les modules historiques. Les colonnes et tables additives peuvent rester en place sans modifier les parcours historiques. Un retour arrière applicatif ne nécessite donc aucune suppression SQL.

## Déploiement

Après le push Git, appliquer les migrations Supabase avec le script de production du dépôt, puis exécuter les contrôles post-déploiement. Ne pas annoncer les fonctionnalités serveur comme actives avant cette application.
