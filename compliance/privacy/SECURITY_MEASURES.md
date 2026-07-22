# Mesures de sécurité et limites

## Mesures présentes dans le dépôt

- Authentification Supabase et blocage des routes métier sans session.
- Isolation par `company_id` et politiques RLS sur les tables métier.
- Rôles explicites: propriétaire, administrateur, facturation, commercial, comptabilité, lecture seule, auditeur et rôle historique limité.
- Permissions sensibles vérifiées côté base pour la finalisation et les encaissements; changements de rôle journalisés.
- Finalisation atomique, snapshots, journal append-only chaîné, paiements corrigés par contre-écriture, clôtures et archives immuables.
- Clés privées et `service_role` interdites dans le navigateur et recherchées par CI.
- Connecteur externe de production, formats réglementés et signature bloqués sans configuration vérifiée.
- Version, schéma, politique de calcul et générateur PDF attachés aux preuves fiscales.

## Mesures d’exploitation requises

- MFA obligatoire pour propriétaires, administrateurs et opérateurs Supabase.
- Rotation des secrets, stockage dans un coffre, séparation développement/test/production.
- Sauvegardes chiffrées, restauration périodiquement testée et preuve approuvée.
- Alertes sur échecs d’authentification, anomalies d’intégrité, dead letters et actions privilégiées.
- Revue trimestrielle des membres, permissions et comptes dormants.
- Correctifs de dépendances, analyse SAST/DAST, test d’intrusion et procédure d’incident exercée.
- Chiffrement de transport, configuration des en-têtes, politique CSP adaptée et contrôle du domaine.
- Gestion des clés KMS avec rotation, double contrôle, révocation et conservation des certificats publics.

## Limites actuelles

- Aucune preuve d’un KMS de production, d’une restauration réelle, d’un test d’intrusion ou d’un audit externe n’est fournie.
- Les migrations doivent encore être exécutées dans le projet Supabase de production et leurs politiques contrôlées avec des comptes de chaque rôle.
- La présence de mécanismes d’intégrité ne vaut ni certification NF 525/NF 203, ni validation AFNOR, ni avis juridique.

