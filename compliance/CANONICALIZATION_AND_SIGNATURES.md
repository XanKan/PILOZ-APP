# Canonicalisation, empreintes et signatures

## État livré

- les événements PostgreSQL utilisent un payload `jsonb`, son SHA-256 et une matière d'événement versionnée ;
- chaque événement contient le hash du précédent et un numéro monotone par entreprise ;
- `verify_fiscal_event_chain` recalcule payloads, maillons et séquences ;
- l'abstraction Edge `FiscalSigner` refuse toute signature tant qu'un KMS n'est pas configuré ;
- aucune clé privée n'est stockée dans le frontend, Git, Storage ou une table utilisateur.

## Canonicalisation actuelle

La version `jsonb-text-v1` repose sur la représentation texte déterministe de PostgreSQL `jsonb` et une matière concaténée dont les champs sont définis par `_fiscal_event_material`. Elle permet des contrôles internes reproductibles dans la même famille de versions PostgreSQL. Elle n'est pas présentée comme un format canonique interopérable universel.

L'utilitaire Edge fournit aussi un tri récursif des clés JSON pour les futurs manifestes hors base. Avant production, un seul format canonique doit être retenu, documenté par octets de test et validé par le spécialiste sécurité et l'organisme certificateur.

## Signature

Les colonnes `signature` et `signature_key_id` restent nulles. Les clôtures sont marquées `unsigned`; les rapports indiquent `not_available_without_kms`. L'activation de production devra être bloquée jusqu'à configuration d'un KMS/HSM, rotation, révocation, conservation des clés publiques et tests de vérification hors application.
