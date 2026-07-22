# Rapport de tests final — 22 juillet 2026

Version : `0.9.0-compliance.2`  
Schéma attendu : `202607220045`  
Environnement : dépôt local Windows, PGlite PostgreSQL embarqué, Chrome headless.  
Portée : validation technique interne; aucun résultat de ce rapport ne vaut certification ou validation juridique.

## Résultats réussis

| Suite | Résultat | Portée |
|---|---|---|
| Toutes les migrations 001→045 + cycle fiscal PGlite | PASS | devis, facture, séquence, finalisation, verrouillage, paiement/correction, clôture, archive, modèle canonique, sandbox, e-reporting, rôles, RGPD, activation |
| `browser-tests.html` | 16/16 | calculs communs |
| `api-response.html` | PASS | réponses vides, 204, type de contenu et JSON invalide |
| `fiscal-domain.html` | PASS | arithmétique en unités mineures et règles fiscales locales |
| `electronic-invoice.html` | 11/11 | modèle canonique et blocage honnête sans profil officiel |
| `erp-smoke.html` | PASS | routes ERP, éditeurs, conformité, modèles et panneaux |
| `production-regression.html` | PASS | régressions critiques frontend |
| `auth-guard.html` | 11/11 | connexion, inscription, session invalide, absence de fuite de vue privée |
| `commercial-workflows.html` | PASS | workflows commerciaux |
| `commercial-workspace.html` | PASS | espace commercial |
| `company-settings-smoke.html` | PASS | paramètres entreprise |
| `document-viewer-v2.html` | PASS | rendu documents |
| `navigation-smoke.html` | PASS | navigation |
| `template-footer-smoke.html` | PASS | pieds de page modèles |
| `template-list-layout.html` | PASS | liste des modèles |
| `fiscal-archive-verifier.mjs` | 7/7 | empreintes, altération détectée, état non signé explicite |
| `verify-release.mjs` | PASS | version, schéma, CNAME et absence d’allégation positive |
| `node --check` des modules modifiés | PASS | syntaxe JavaScript |

## Contrôles particuliers réussis

- facture brouillon sans numéro puis attribution atomique `FAC-2026-0001` à la finalisation;
- document fiscal marqué `legacy_unsecured` tant que le moteur renforcé n’est pas activé;
- écriture de paiement initiale immuable et correction par montant inverse;
- clôture et archive immuables, état `unsigned` explicite;
- sandbox idempotent sans passage mensonger au statut transmis;
- utilisateur Lecture seule sans droit de finalisation ni accès au tableau de conformité;
- propriétaire impossible à rétrograder via CRUD ou RPC générique;
- activation production refusée sans preuves externes, KMS et profil officiel;
- registre de certifications vide par défaut et insertion directe refusée;
- contrôle d’intégrité daté et empreinté;
- demande de droit enregistrée avec échéance.

## Non exécuté ou volontairement bloqué

- test de concurrence réel multi-connexion sur PostgreSQL Supabase;
- RLS croisée avec deux entreprises dans le projet de préproduction Supabase;
- restauration d’une sauvegarde réelle DB + Storage;
- signature KMS et vérification de certificat;
- génération/validation officielle UBL, CII ou Factur-X;
- webhook réel signé, retry réseau et dead-letter d’une plateforme réelle;
- transmission e-invoicing/e-reporting de production;
- test d’intrusion, audit juridique, AFNOR ou organisme certificateur;
- purge RGPD automatique, volontairement non activée avant validation des durées.

Ces contrôles restent des prérequis bloquants avant toute activation de production ou déclaration de conformité.

