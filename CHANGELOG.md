# Changelog

## 0.9.0-compliance.20 — 25 juillet 2026

- le bouton « Facture » crée et ouvre directement une facture classique en brouillon, sans fenêtre d’avancement intermédiaire ;
- ajout de l’option persistante « Facture de situation » dans le panneau droit du brouillon issu d’un devis ;
- la colonne et les réglages d’avancement apparaissent uniquement lorsque cette option est activée ;
- activation et désactivation atomiques du mode situation, avec restauration des quantités originales.

## 0.9.0-compliance.19 — 25 juillet 2026

- toutes les lignes du devis restent disponibles et modifiables dans chaque situation brouillon, y compris N°2, N°3 et suivantes ;
- toutes les lignes sont conservées sur le PDF de situation, y compris celles à 0 % et 0 € ;
- rattrapage non destructif des situations brouillon déjà créées ;
- référence provisoire stable `BR-AAAA-XXXXXXXX` affichée sur les factures brouillon, sans consommer la séquence fiscale ;
- filigrane `FACTURE PROVISOIRE` sur chaque page de l’aperçu PDF d’une facture brouillon.

## 0.9.0-compliance.18 — 25 juillet 2026

- Factures de situation cumulatives sans limite : Situation N°1, N°2, etc.
- Avancement configurable sur la totalité, par titre et par ligne, sans retour sous le pourcentage précédent.
- Création de la situation suivante depuis la facture finalisée et facture de solde à 100 %.
- Numéro fiscal attribué dans la séquence normale des factures lors de la finalisation.
- Numéro de situation et avancement visibles dans l’éditeur, les documents liés et le PDF.

## 0.9.0-compliance.17 — 25 juillet 2026

- le devis déjà facturé affiche de nouveau l’action « Modifier », désormais grisée et désactivée ;
- une explication indique de créer un avoir sur la facture liée puis de dupliquer le devis avant de recommencer le chiffrage ;
- retrait de l’action trompeuse « Modifier via une nouvelle version ».

## 0.9.0-compliance.16 — 25 juillet 2026

- retrait des notes publiques saisissables dans les devis, factures, préférences client et PDF ;
- acompte simplifié en une valeur suivie d’un choix `%` ou `€` ;
- conservation de la position de défilement pendant les modifications et les filtres ;
- fermeture des calendriers, recherches client et listes de filtres par clic extérieur ;
- saisie d’une ligne ponctuelle conservée automatiquement sans bouton de confirmation.

## 0.9.0-compliance.15 — 25 juillet 2026

- Corrige l’association du modèle configuré lors de la création et de l’enregistrement d’un devis ou d’une facture.
- Empêche les thèmes temporaires de l’ancien atelier d’apparence de remplacer les modèles métier existants.
- Réaligne les références de modèle des brouillons et leur aperçu PDF sans modifier les documents finalisés.

## 0.9.0-compliance.14 — 25 juillet 2026

- retrait du bloc « Destinataire et adresses » dans l’éditeur des devis et factures ;
- conservation silencieuse des informations de contact et d’adresse déjà associées aux documents ;
- aucune suppression des contacts ou adresses enregistrés dans Supabase.

## 0.9.0-compliance.13 — 25 juillet 2026

- fermeture automatique de l’éditeur après l’enregistrement réussi d’un modèle ;
- retour direct à la liste Paramètres > Modèles ;
- conservation de l’éditeur et des modifications en cas d’échec d’enregistrement.

## 0.9.0-compliance.12 — 25 juillet 2026

- restauration de l’éditeur historique des modèles de devis et de factures ;
- retrait de la nouvelle interface Apparence et de son rendu PDF ;
- conservation non destructive de la migration additive déjà appliquée, sans suppression de données existantes.

## 0.9.0-compliance.10 — 24 juillet 2026

- carte bancaire collectée par Stripe avant la création du compte, sans débit pendant les 14 jours d’essai ;
- rattachement sécurisé du Checkout au compte créé, avec jeton à usage unique conservé uniquement sous forme d’empreinte SHA-256 ;
- changement d’offre confirmé dans Stripe avant toute modification de l’abonnement Piloz ;
- portail Stripe configuré automatiquement pour les moyens de paiement, coordonnées de facturation, factures et résiliation ;
- synchronisation du nom, de l’adresse, du numéro de TVA, de la carte masquée et des PDF de factures dans Paramètres > Abonnement.

## 0.9.0-compliance.9 — 24 juillet 2026

- nouveau cockpit de pilotage connecté aux données Supabase réelles, avec quatre indicateurs principaux, analyse temporelle, trésorerie, priorités et blocs métier ;
- personnalisation du tableau de bord enregistrée par utilisateur et par entreprise, avec ordre, taille, visibilité, période et densité ;
- calculs financiers centralisés côté PostgreSQL, permissions par rôle et isolation stricte par entreprise ;
- optimisation et tests de charge validés sur 10 001 clients, 50 000 factures, 100 000 paiements, 50 000 activités et 20 000 articles ;
- affichage responsive, états vides, navigation contextuelle, accessibilité clavier et repli contrôlé vers l’ancien tableau de bord tant que la migration n’est pas active.

## 0.9.0-compliance.8 — 24 juillet 2026

- correction additive de `public.has_feature` : le paramètre de fonctionnalité est désormais référencé sans ambiguïté avec la colonne SQL homonyme ;
- le contrôle SQL de production peut de nouveau terminer le déploiement.

## 0.9.0-compliance.7 — 24 juillet 2026

- autorisation des actions du back-office pendant toute la session MFA active ;
- suppression de la ressaisie répétée du mot de passe et du code TOTP ;
- conservation de l’expiration pour inactivité, des rôles, permissions et audits.

## 0.9.0-compliance.6 — 24 juillet 2026

- fondation additive du back-office Piloz séparé de l’application cliente ;
- rôles plateforme, permissions serveur et MFA AAL2 obligatoires ;
- versions contractuelles des plans et calculs MRR/ARR documentés ;
- suspension réversible des entreprises, sans suppression de données ;
- sessions support temporaires et journal d’administration chaîné append-only ;
- API Edge sécurisée sans clé `service_role` dans le navigateur.

Le back-office de production reste volontairement désactivé tant que le premier super-administrateur avec MFA et les contrôles post-déploiement ne sont pas validés.

## 0.9.0-compliance.2 — 22 juillet 2026

- rôles métier et permissions sensibles côté PostgreSQL ;
- changements d’accès journalisés et propriétaire protégé ;
- registres RGPD, preuves, contrôles d’intégrité, anomalies et certifications réelles éventuelles ;
- activation fiscale contrôlée et bloquée sans prérequis vérifiés ;
- écrans administrateur de conformité et de version ;
- documentation RGPD, sécurité, opérations fiscales et rapport de tests final.

Le moteur de production reste désactivé. Cette pré-release ne constitue aucune certification, homologation ou validation juridique.

## 0.9.0-compliance.1 — 22 juillet 2026

- audit, matrice, risques et registre de preuves ;
- calculs serveur, validation, numérotation et finalisation renforcés ;
- journal fiscal chaîné, paiements append-only et clôtures ;
- archives manifestées et vérificateur autonome ;
- modèle canonique de facture et blocage des formats normatifs non validés ;
- sandbox de plateforme explicitement simulé et préclassification e-reporting ;
- système qualité, CI et manifeste de release.

Cette pré-release ne constitue pas une certification NF 525/NF 203, une conformité AFNOR, une homologation ou une conformité validée à la réforme.
## 0.9.0-compliance.5 — 23 juillet 2026

- Filtres de dates unifiés pour les devis et factures : 7 derniers jours, mois/année courants ou précédents et calendrier personnalisé.
- Nouvelle fiche client dédiée avec recherche, filtres, indicateurs et treize rubriques métier.
- Contacts, rôles et adresses multiples, préférences commerciales et comptes auxiliaires historisés.
- Onglet Comptabilité client volontairement limité à la saisie du code auxiliaire ; le paramétrage général est réservé à une version ultérieure.
- Sélection du destinataire et des adresses dans les devis/factures, figée dans les snapshots.
- RLS renforcée pour les rôles en lecture seule et stockage privé des pièces client.
