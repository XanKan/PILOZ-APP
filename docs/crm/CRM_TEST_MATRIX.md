# Matrice de tests CRM et Command Center

Les contrôles sont répartis entre tests SQL PGlite, tests navigateur statiques et recette Supabase authentifiée.

## Automatisés

- chargement de toutes les migrations ;
- présence et sécurité des RPC CRM ;
- création des pipelines et étapes par défaut ;
- isolation entreprise A/B ;
- déplacement atomique et historique ;
- fermeture gagnée/perdue avec motif obligatoire ;
- conversion sans duplication de l'identifiant prospect ;
- score explicable et historique ;
- agrégations pipeline, prévisions, priorités et rapports ;
- préférences du Command Center ;
- rendu Kanban/liste/prévisions/calendrier ;
- restauration optimiste après échec ;
- navigation et anciens liens ;
- recherche et pagination.
- administration multi-pipeline, duplication et réordonnancement des étapes ;
- import CSV, mise à jour des doublons et fusion avec conservation de l'historique ;
- recherche globale incluant les contacts ;
- replanification agenda persistée ;
- vues enregistrées idempotentes ;
- traitement d'un e-mail synchronisé et isolation d'une boîte personnelle ;
- refus d'écriture pour un rôle lecture seule et politiques RLS granulaires.
- limitation des agrégats et du pipeline aux données attribuées pour un commercial ;
- journal d’automatisation, échec contrôlé, retry réel et refus du retry en lecture seule.
- charge CRM reproductible : 100 000 prospects, 50 000 opportunités et 500 000 activités ; pagination, recherche filtrée, Kanban, rapports et Command Center agrégés en 5,445 s sous PGlite.

## Recette authentifiée requise

- connecteurs Gmail/Outlook/Agenda réels ;
- import CSV avec un fichier métier réel ;
- consentements et désabonnement des séquences ;
- envoi d'e-mail uniquement avec un connecteur actif ;
- responsive sur les navigateurs et terminaux cibles ;
- contrôle des permissions avec les rôles réellement configurés en production.
- application effective des migrations jusqu'à `202607260079` et déploiement de l'Edge Function `external-integrations`.

Une fonctionnalité nécessitant un connecteur externe affiche une action de connexion et ne simule jamais une réussite.
