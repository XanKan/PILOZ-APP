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

Les archives fiscales peuvent être signées par une clé asymétrique AWS KMS `SIGN_VERIFY`. Piloz transmet uniquement leur empreinte SHA-256 avec `MessageType=DIGEST`, utilise par défaut `RSASSA_PSS_SHA_256`, vérifie immédiatement le résultat auprès du KMS, puis conserve la signature et ses métadonnées dans `fiscal_archive_signatures`. Cette table est append-only, protégée par RLS et séparée de l'archive déjà figée.

Sans secrets KMS, l'export reste explicitement `unsigned` et aucune signature n'est simulée. Le manifeste de release conserve `kms_configured=false` tant que la clé réelle n'est pas activée et testée en production. Les clôtures fiscales restent encore `unsigned` : leur signature devra être raccordée séparément avant toute revendication de conformité globale.

La configuration opérationnelle, les droits IAM minimaux, la rotation et le test sont décrits dans `docs/AWS_KMS_FISCAL_SIGNATURES.md`. Une signature KMS améliore l'intégrité et la preuve d'altération ; elle ne constitue pas à elle seule une certification NF525/NF203 ou une signature électronique qualifiée.
