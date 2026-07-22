# Rapport de tests final — 22 juillet 2026

Version : `0.9.0-compliance.3`
Schéma attendu : `202607220047`
Environnement : dépôt local Windows, PGlite PostgreSQL embarqué, Chrome headless.
Portée : validation technique interne; aucun résultat de ce rapport ne vaut certification ou validation juridique.

## Résultats réussis

| Suite | Résultat | Portée |
|---|---|---|
| Toutes les migrations 001→047 + cycle fiscal PGlite | PASS | devis, facture, séquence, finalisation, verrouillage, paiement/correction/remboursement, trop-perçu, clôture, archive, modèle canonique, sandbox, e-reporting, rôles, RGPD, maintenance et activation |
| `browser-tests.html` | 16/16 | calculs communs |
| `api-response.html` | PASS | réponses vides, 204, type de contenu et JSON invalide |
| `fiscal-domain.html` | PASS | arithmétique en unités mineures et règles fiscales locales |
| `electronic-invoice.html` | 15/15 | modèle canonique, classification et blocage honnête sans profil officiel |
| `erp-smoke.html` | 44/44 | routes ERP, éditeurs, conformité, modèles et panneaux |
| `production-regression.html` | 10/10 | régressions critiques frontend |
| `auth-guard.html` | 11/11 | connexion, inscription, session invalide, absence de fuite de vue privée |
| `commercial-workflows.html` | 46/46 | workflows commerciaux |
| `commercial-workspace.html` | 84/84 | espace commercial |
| `company-settings-smoke.html` | 7/7 | paramètres entreprise |
| `document-viewer-v2.html` | 78/78 | rendu documents, réception et incidents de paiement |
| `navigation-smoke.html` | 17/17 | navigation |
| `template-footer-smoke.html` | 16/16 | pieds de page modèles |
| `template-list-layout.html` | 6/6 | liste des modèles |
| `fiscal-archive-verifier.mjs` | 7/7 | empreintes, altération détectée, état non signé explicite |
| `verify-release.mjs` | PASS | version, schéma, CNAME et absence d’allégation positive |
| `node --check` des modules modifiés | PASS | syntaxe JavaScript |

## Contrôles particuliers réussis

- facture brouillon sans numéro puis attribution atomique `FAC-2026-0001` à la finalisation;
- document fiscal marqué `legacy_unsecured` tant que le moteur renforcé n’est pas activé;
- écriture de paiement initiale immuable et correction, remboursement, rejet ou chargeback par écriture inverse partielle ou totale;
- ventilation atomique d’un règlement supérieur au solde entre paiement affecté et trop-perçu;
- clôture et archive immuables, état `unsigned` explicite;
- sandbox idempotent sans passage mensonger au statut transmis;
- utilisateur Lecture seule sans droit de finalisation ni accès au tableau de conformité;
- propriétaire impossible à rétrograder via CRUD ou RPC générique;
- activation production refusée sans preuves externes, KMS et profil officiel;
- registre de certifications vide par défaut et insertion directe refusée;
- contrôle d’intégrité daté et empreinté;
- demande de droit enregistrée avec échéance, transitions et décisions journalisées;
- export RGPD éphémère vérifié par empreinte sans duplication persistante des données exportées;
- règles de conservation modifiables et aperçu non destructif des actions;
- détection des clôtures manquantes, exécution à blanc et journal de maintenance immuable.

## Non exécuté ou volontairement bloqué

- test de concurrence réel multi-connexion sur PostgreSQL Supabase;
- RLS croisée avec deux entreprises dans le projet de préproduction Supabase;
- restauration d’une sauvegarde réelle DB + Storage;
- signature KMS et vérification de certificat;
- génération/validation officielle UBL, CII ou Factur-X;
- webhook réel signé, retry réseau et dead-letter d’une plateforme réelle;
- transmission e-invoicing/e-reporting de production;
- test d’intrusion, audit juridique, AFNOR ou organisme certificateur;
- purge RGPD automatique, volontairement non activée avant validation des durées;
- exécution réelle du Cron de clôture en production, à activer après migration et validation métier.

Ces contrôles restent des prérequis bloquants avant toute activation de production ou déclaration de conformité.
