# Permissions et confidentialité des Activités

## Permissions

| Permission | Usage |
|---|---|
| `activities.read` / `crm.activities.read` | consulter la portée autorisée |
| `activities.create` | créer |
| `activities.update` | modifier |
| `activities.complete` | terminer avec résultat |
| `activities.cancel` | annuler |
| `activities.archive` / `crm.activities.archive` | archiver |
| `activities.assign` | assigner ou réassigner |
| `activities.read_team` | consulter l’équipe |
| `activities.read_company` | consulter l’entreprise |
| `activities.manage_types` / `crm.activities.configure` | configurer les types |
| `activities.manage_private` / `crm.activities.confidential.read` | accès exceptionnel aux activités privées |
| `activities.export` | exporter les éléments visibles |
| `activities.sync_calendar` | synchroniser son agenda |
| `activities.sync_email` | historiser via une messagerie connectée |

## Portées

- `own` : auteur ou responsable ;
- `team` : membre de l’équipe autorisée ;
- `company` : entreprise active autorisée.

La permission seule ne suffit pas à contourner une activité privée. La politique restrictive conserve l’accès à l’auteur, au responsable, aux participants internes et aux rôles explicitement habilités.

## Défense en profondeur

- résolution de l’entreprise côté serveur ;
- validation de chaque relation dans la même entreprise ;
- contrôle de portée pour l’assignation ;
- RLS sur les tables principales, associées et le stockage ;
- fonctions d’écriture `SECURITY DEFINER` avec `search_path` figé ;
- retraits des droits directs d’écriture sur les tables sensibles ;
- liens de téléchargement temporaires ;
- événements non modifiables depuis le navigateur.

