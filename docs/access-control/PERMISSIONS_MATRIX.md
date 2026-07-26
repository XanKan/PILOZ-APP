# Matrice des rôles et permissions

Cette matrice décrit les quatre rôles Piloz livrés par défaut. Ces rôles sont visibles et assignables, mais ils ne peuvent pas être renommés, modifiés, archivés ou supprimés. Pour adapter un rôle, il faut le dupliquer et modifier la copie.

Les portées disponibles sont :

- `own` : données dont l’utilisateur est responsable ;
- `team` : données de l’utilisateur et de son équipe ;
- `company` : toutes les données de l’entreprise.

## Administrateur

L’Administrateur possède toutes les permissions actives à l’échelle de l’entreprise : utilisateurs, rôles, paramètres, ventes, achats, règlements, comptabilité et conformité.

Piloz refuse toute opération qui laisserait une entreprise sans administrateur actif.

## Utilisateur

Le rôle Utilisateur couvre les opérations courantes : tableau de bord personnel, clients et CRM personnels, brouillons de devis, lecture de ses factures et règlements, catalogue et préférences personnelles. Il n’accorde aucun droit d’administration avancée.

## Commercial

| Domaine | Permission | Portée |
|---|---|---|
| Tableau de bord | Consulter | Ses données |
| Clients | Consulter et modifier | Son équipe |
| Prospects, opportunités, activités, relances | Consulter et modifier | Son équipe |
| Rapports CRM | Consulter | Ses données |
| Devis | Consulter | Son équipe |
| Devis | Créer, modifier un brouillon, finaliser, envoyer, convertir | Ses données, sauf lecture/envoi équipe |
| Factures | Consulter et envoyer | Son équipe |
| Factures | Créer et modifier ses brouillons | Ses données |
| Échéances et relances | Consulter et relancer | Son équipe |
| Paiements | Consulter | Son équipe |
| Catalogue | Consulter | Entreprise |

Le Commercial ne peut pas :

- finaliser une facture ;
- enregistrer, corriger ou annuler un règlement ;
- créer un avoir ;
- consulter les coûts d’achat ou les marges ;
- accéder à la comptabilité, aux paramètres d’entreprise, aux utilisateurs ou au stock.

## Expert-comptable

| Domaine | Permission | Portée |
|---|---|---|
| Clients | Lecture | Entreprise |
| Factures et échéances | Lecture | Entreprise |
| Paiements, références bancaires, justificatifs | Lecture | Entreprise |
| Écritures comptables | Lecture | Entreprise |
| Exports comptables | Gestion | Entreprise |
| Paramétrage comptable et TVA | Gestion | Entreprise |
| Conformité fiscale | Lecture | Entreprise |

L’Expert-comptable n’a aucun droit d’écriture commercial, de finalisation de facture ou de saisie de paiement.

## Rôles personnalisés

Un rôle personnalisé peut partir d’un rôle vide ou de la copie d’un rôle existant. Chaque permission est activée séparément et, lorsque le catalogue le permet, associée à une portée `own`, `team` ou `company`.

Les changements sont appliqués immédiatement, journalisés et protégés côté base de données. Une simple réapparition visuelle d’un bouton ne suffit donc pas à contourner une interdiction.

Le module Stock et ses autorisations sont volontairement absents de l’éditeur de rôles. Ils sont conservés techniquement pour une future version inscrite à la roadmap.
