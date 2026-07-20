# Recette de la refonte commerciale

## Contrôles automatisés

- `tests/browser-tests.html` couvre les 16 calculs commerciaux, dont HT, TVA, TTC, marge, taux de marge et taux de marque ;
- `tests/erp-smoke.html` parcourt les routes ERP, les listes, les éditeurs et les panneaux rapides en capturant les erreurs JavaScript ;
- `supabase/tests/rls_acceptance.sql` contrôle la structure, les politiques RLS, les droits sur les colonnes sensibles, les RPC et l’isolation de deux entreprises ;
- la migration `202607200006_modern_commercial_suite.sql` est additive : aucune table ni donnée historique n’est supprimée.

## Matrice des 47 demandes

| # | Contrôle | Couverture |
|---:|---|---|
| 1–3 | Connexion, tableau de bord, navigation | Session Supabase conservée, données réelles, 7 rubriques et sous-navigation responsive |
| 4–7 | Clients particuliers/professionnels, adresse et entreprise | Panneau rapide, Géoplateforme et recherche entreprise côté Edge |
| 8–12 | Article, achats/ventes, marge et TVA | Catalogue persistant, calculs testés, taux issus de `vat_rates` |
| 13–23 | Devis, ligne ponctuelle, création catalogue, sections, totaux, aperçu, liste et filtres | Éditeur pleine page et liste professionnelle reliés à Supabase |
| 24–29 | Facturation, acompte, avoir, paiements et échéances | Conversions et paiements atomiques via RPC, échéanciers persistants |
| 30–32 | Pipeline et widgets N/N-1 | Étapes et automatisations configurables, widgets persistants sans fausses valeurs |
| 33–37 | Fournisseurs, commandes, réceptions, mouvements et inventaires | Flux achats/stock existants conservés, mouvements et réceptions transactionnels |
| 38–41 | Modèles, visuel, code et aperçu | Blocs, réglages, glisser-déposer, assainissement, validation des variables et versions |
| 42–44 | Reconnexion, conservation et isolation | Auth Supabase, données persistantes et RLS par `company_id` |
| 45–46 | Responsive et absence d’erreur bloquante | CSS mobile/tablette et test de rendu dans Chrome headless |
| 47 | Absence de secret | scan Git avant publication ; aucun `.env`, `service_role` ou jeton privé suivi |

## Limites d’intégration externes

Les recherches d’entreprise et d’adresse fonctionnent sans secret privé dans le navigateur. L’envoi réel d’e-mails et la vérification SMS ne sont activés que si `RESEND_API_KEY`/`EMAIL_FROM` et les secrets Twilio sont configurés dans Supabase ; l’interface renvoie sinon une erreur explicite et ne simule pas de succès.
