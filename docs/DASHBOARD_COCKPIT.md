# Cockpit de pilotage PILOZ

## Architecture

Le tableau de bord principal repose sur un seul appel coordonné à
`get_dashboard_cockpit`. La fonction détermine l'entreprise active à partir de
`auth.uid()` et de `user_preferences.company_id` ; aucun `company_id` envoyé par
le navigateur n'est accepté. Elle assemble des agrégats spécialisés :

- synthèse financière ;
- série temporelle ;
- prévision des encaissements ;
- actions prioritaires ;
- balance âgée ;
- activité commerciale ;
- documents récents ;
- performances clients et catalogue ;
- stock, agenda, achats et notifications.

Les fonctions sont `SECURITY DEFINER` avec un `search_path` fixe. Les droits
d'exécution ne sont accordés qu'au rôle `authenticated`. Les données sont
filtrées par entreprise et, pour un commercial, par responsable ou créateur.
Les marges, prix d'achat et stocks sont retirés de la réponse lorsque le rôle ne
possède pas la permission correspondante.

Le navigateur conserve un cache de deux minutes isolé par entreprise,
utilisateur, période et comparaison. Un changement de période annule la requête
devenue obsolète avec `AbortController`. L'actualisation manuelle invalide ce
cache sans recharger toute la page.

## Composition visuelle

La composition principale est volontairement fixe :

1. en-tête, période et actions rapides ;
2. quatre indicateurs au maximum ;
3. graphique de performance et prévision ;
4. actions prioritaires.

Les blocs secondaires sont personnalisables : échéances, activité commerciale,
documents, clients, catalogue, stock, agenda, achats, notifications et
prévisions détaillées. Ils peuvent être masqués, agrandis et déplacés par
glisser-déposer uniquement dans le mode **Personnaliser**. L'enregistrement est
explicite ; Annuler restaure la dernière disposition sauvegardée.

La préférence est stockée dans `dashboard_preferences`, avec une contrainte
unique `(company_id, user_id)` et des politiques RLS limitées à l'utilisateur
connecté. Les anciennes lignes `dashboard_widgets` sont reprises de manière
additive, sans être supprimées.

## Définitions financières

### Chiffre d'affaires facturé HT

Somme HT des factures finalisées sur la période, diminuée des avoirs finalisés.
Un devis et une facture brouillon ne constituent jamais du chiffre d'affaires.

### Encaissements

Somme des écritures confirmées du registre `payments` à la date réelle de
paiement. Les corrections, remboursements, rejets et chargebacks sont des
écritures négatives et diminuent donc le montant encaissé.

### Reste à encaisser

Somme TTC des factures finalisées encore ouvertes à la fin de la période,
diminuée des paiements confirmés et des avoirs liés enregistrés à cette date.
L'indicateur inclut les factures antérieures qui sont toujours ouvertes.

### Marge brute

Chiffre d'affaires HT net moins `total_cost`, avec le même signe négatif pour
les avoirs. La valeur n'est pas envoyée au navigateur sans la permission
`view_margins`.

### Taux de transformation

Nombre de devis acceptés ou déjà facturés divisé par le nombre de devis ayant
reçu une décision (accepté, facturé ou refusé). Aucun pourcentage n'est renvoyé
si le dénominateur est nul.

### Panier moyen

Chiffre d'affaires facturé HT net divisé par le nombre de factures finalisées
retenues. Les avoirs diminuent le numérateur mais ne sont pas comptés comme des
factures supplémentaires.

### Délai moyen de paiement

Moyenne du nombre de jours entre la date d'émission de la facture et la date des
écritures positives de paiement enregistrées sur la période.

## Périodes

Les bornes sont calculées dans PostgreSQL avec le fuseau de l'entreprise :
aujourd'hui, semaine en cours, 7 ou 30 derniers jours, mois en cours ou
précédent, trimestre, année en cours ou précédente et dates personnalisées.
Une comparaison peut viser la période précédente, la même période de l'année
précédente ou être désactivée.

## Déploiement

La migration additive est
`supabase/migrations/202607240056_dashboard_cockpit.sql`. Tant qu'elle n'est pas
appliquée au projet Supabase, l'application conserve automatiquement l'ancien
tableau de bord et affiche une information non bloquante. Après application, le
nouveau cockpit devient actif sans conversion destructrice des données.

La correspondance détaillée avec les 92 scénarios demandés est documentée dans
`docs/DASHBOARD_TEST_MATRIX.md`.
