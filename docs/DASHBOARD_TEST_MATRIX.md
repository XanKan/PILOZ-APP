# Matrice de vérification du cockpit

Cette matrice relie les 92 contrôles demandés aux preuves automatisées. Les
tests PostgreSQL appliquent **toutes** les migrations dans une base PGlite
vierge ; les tests navigateur chargent le véritable module du cockpit avec une
API contrôlée. Ils n'ajoutent aucune donnée fictive à l'application de
production.

## Structure et indicateurs — contrôles 1 à 15

| Contrôles | Preuve principale | Vérification |
| --- | --- | --- |
| 1–7 | `tests/dashboard-cockpit.html`, desktop et mobile 390×844 | En-tête, prénom, périodes, comparaison, actions, responsive, skeleton et état d'accueil |
| 8–14 | `tests/dashboard-cockpit-pglite.cjs` | CA net, encaissement corrigé, reste à encaisser, marge, comparaison et division par zéro |
| 15 | `tests/dashboard-cockpit.html` | Navigation contextuelle vers documents, clients et modules filtrés |

## Graphique et prévisions — contrôles 16 à 31

| Contrôles | Preuve principale | Vérification |
| --- | --- | --- |
| 16–18 | `get_revenue_timeseries`, bornes testées dans PGlite | Granularité serveur automatique jour/semaine/mois/année |
| 19–24 | `tests/dashboard-cockpit-pglite.cjs` | Facturé, encaissé, marge, comparaison, avoir de 100 €, correction de paiement de 100 € |
| 25–26 | `tests/dashboard-cockpit.html` | Infobulles riches et tableau textuel accessible du graphique |
| 27–31 | `get_cash_collection_forecast`, test navigateur | Échéances et retards réels ; plans/promesses utilisés lorsqu'ils existent, sans en inventer ; navigation vers les échéances |

## Pilotage opérationnel — contrôles 32 à 64

| Contrôles | Preuve principale | Vérification |
| --- | --- | --- |
| 32–38 | PGlite + navigateur | Factures/devis/activités/stock prioritaires, tri serveur, actions directes et permissions |
| 39–44 | `get_sales_funnel_summary` + navigateur | Étapes commerciales, taux et navigation filtrée |
| 45–49 | `get_dashboard_recent_documents` + navigateur | Maximum cinq documents par type, ouverture contextuelle, aucune liste complète chargée |
| 50–54 | `get_customer_performance_summary` + PGlite | Nouveaux/principaux clients, CA, encaissement, solde et périmètre commercial |
| 55–59 | catalogue + stock PGlite | Produits/services, ventes, marge, prix manquant, stock faible et masquage des coûts |
| 60–64 | activité PGlite + navigateur | Aujourd'hui, retard, prochaines activités, action Terminer et affectation |

## Personnalisation et sécurité — contrôles 65 à 84

| Contrôles | Preuve principale | Vérification |
| --- | --- | --- |
| 65–72 | `tests/dashboard-cockpit.html` | Mode explicite, DnD clavier/souris, ajout/masquage, taille bornée, sauvegarde, annulation et reset par rôle |
| 73–74 | `tests/dashboard-cockpit-pglite.cjs` | Contrainte et RLS `(company_id, user_id)`, dispositions différentes par entreprise |
| 75–81 | PGlite | RLS, entreprises A/B, propriétaire/commercial/lecture seule, réponse expurgée, `SECURITY DEFINER` à `search_path` fixe |
| 82–84 | workflow `compliance-checks.yml` | Recherche de secrets et `service_role`, refus des `.env` suivis, CNAME exact |

## Performance — contrôles 85 à 92

| Contrôles | Preuve principale | Vérification |
| --- | --- | --- |
| 85–86 | navigateur | Skeleton immédiat, un appel analytique coordonné, listes secondaires plafonnées |
| 87–88 | `tests/dashboard-performance-pglite.cjs` | 50 000 factures et 100 000 paiements, avec 10 001 clients, 50 000 activités et 20 000 articles |
| 89, 92 | navigateur | Debounce et annulation `AbortController` lors d'un changement rapide |
| 90 | test de charge PGlite | Agrégation en requêtes ensemblistes, résultat constant sans boucle N+1 |
| 91 | navigateur + PGlite | Cache indexé par utilisateur/entreprise/période/permissions et isolation A/B |

## Commandes de reproduction

```powershell
$env:PILOZ_PGLITE_ROOT="$env:TEMP\piloz-pglite-current\node_modules\@electric-sql\pglite"
node tests/dashboard-cockpit-pglite.cjs
node tests/dashboard-performance-pglite.cjs

$env:PILOZ_PLAYWRIGHT_ROOT="$env:TEMP\piloz-playwright\node_modules\playwright-core"
$env:PILOZ_CHROME_PATH="C:\Program Files\Google\Chrome\Application\chrome.exe"
node tests/run-html-tests.cjs tests/dashboard-cockpit.html
$env:PILOZ_VIEWPORT_WIDTH="390"
$env:PILOZ_VIEWPORT_HEIGHT="844"
node tests/run-html-tests.cjs tests/dashboard-cockpit.html
```

Le parcours connecté réel doit encore être rejoué sur `app.piloz.fr` après
l'application de la migration `202607240056` dans Supabase. Avant cette
application, le frontend revient volontairement à l'ancien tableau de bord au
lieu d'afficher des valeurs inventées.
