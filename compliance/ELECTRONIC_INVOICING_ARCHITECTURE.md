# Architecture de préparation à la facturation électronique

## Positionnement honnête

Piloz est préparé comme solution de gestion **connectable** à une plateforme agréée. Piloz n'est pas une plateforme agréée, ne dispose pas encore d'un connecteur de production validé et ne revendique aucune conformité AFNOR ou réglementaire.

Les pages publiques consultées le 22 juillet 2026 confirment l'existence des éditions XP Z12-012, XP Z12-013 et XP Z12-014 de juin 2026. Les textes complets et leurs artefacts de validation ne sont pas fournis dans le dépôt. Les profils exacts restent donc à contrôler sur les sources sous licence et auprès de la plateforme retenue.

Sources de cadrage :

- https://www.boutique.afnor.org/fr-fr/norme/xp-z12012/formats-et-profils-des-messages-factures-et-statuts-de-cycle-de-vie-constit/fa301169/601641
- https://www.boutique.afnor.org/fr-fr/norme/xp-z12013/api-pour-interfacer-les-systemes-dinformations-des-entreprises-avec-les-pla/fa301170/601639
- https://www.boutique.afnor.org/fr-fr/norme/xp-z12014/-cas-dusage-b2b-applicables-dans-le-cadre-la-reforme-facture-electronique-e/fa301171/601640
- https://www.impots.gouv.fr/facturation-electronique-et-plateformes-agreees

## Couches

1. Le snapshot fiscal reste la source figée.
2. `build_canonical_invoice` construit `piloz-canonical-invoice/1.0` : fournisseur, client, adresses, identifiants, facture, lignes, ventilation TVA, paiements, références, livraison, données de reporting, cycle de vie et versions.
3. `create_canonical_invoice_record` conserve le modèle et son SHA-256, puis un rapport de règles métier. L'enregistrement est append-only.
4. Le registre `electronic_format_profiles` décrit un profil officiel, ses chemins XSD/Schematron et leurs empreintes. Il est vide par défaut.
5. Les adaptateurs UBL, CII et Factur-X sont des interfaces serveur. En l'absence de profil vérifié et d'adaptateur testé, ils lèvent `official_profile_not_configured` et ne produisent aucun XML.
6. Les artefacts originaux, PDF associés et rapports seront conservés par `electronic_invoice_artifacts` lorsqu'un adaptateur est installé.

## Données contextuelles

La migration ajoute sans les rendre universellement obligatoires : catégorie client, adresses de livraison, e-mail et identifiants de routage, plateforme choisie, catégorie d'opération, date de livraison/prestation et références contractuelles. Les règles dépendent du cas B2B/B2C, du pays et de l'opération. Un champ absent donne un avertissement ou un blocage explicite ; aucune valeur n'est inventée.

## Installation future d'un profil

Une installation doit fournir la source, version, date, licence, XSD, Schematron, empreintes SHA-256, jeux valides/invalides et rapport de validation. Le profil n'obtient `verified` qu'après revue. Une nouvelle version crée une nouvelle ligne ; elle ne remplace pas silencieusement celle utilisée par un ancien document.

## Limites

- seuls le modèle canonique JSON et ses règles internes sont opérationnels ;
- exports UBL/CII/Factur-X, XSD, Schematron et format mixte : bloqués et non implémentés sans sources officielles ;
- mapping complet des cas XP Z12-014 : validation externe requise ;
- statut et API de plateforme : phase 6 ;
- aucun fichier généré par cette phase ne doit être transmis en production.
