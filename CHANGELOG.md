# Changelog

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
