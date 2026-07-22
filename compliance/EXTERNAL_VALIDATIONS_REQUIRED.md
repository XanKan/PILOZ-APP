# Validations externes requises

## Référentiels et certification

1. Obtenir légalement les éditions en vigueur des référentiels NF 525 et NF 203 et les intégrer au processus de revue sans les publier dans Git.
2. Obtenir et étudier les éditions de juin 2026 de XP Z12-012, XP Z12-013 et XP Z12-014 ainsi que leurs documents joints et artefacts de validation autorisés.
3. Faire confirmer le périmètre NF 525 applicable à Piloz, notamment l'enregistrement d'encaissements, les clôtures, la signature et l'archivage.
4. Faire confirmer le périmètre NF 203, l'organisation qualité et les preuves attendues.
5. Faire valider le choix de canonicalisation, de hash, de signature, de rotation et de KMS par un spécialiste sécurité et l'organisme certificateur pressenti.

## Droit et fiscalité

- Revue des mentions obligatoires et conditionnelles par type d'entreprise, client, opération, TVA, devise, acompte et avoir.
- Revue des règles de correction, remboursement, annulation, dates, exigibilité et conservation.
- Revue de l'applicabilité de l'article 286 du CGI au périmètre exact de Piloz.
- Revue de la classification e-invoicing/e-reporting et du calendrier applicable à chaque utilisateur.
- Revue RGPD de la cartographie, des durées, de l'anonymisation et des demandes de droits.

## Prestataires et exploitation

- Sélectionner une plateforme agréée figurant sur la liste officielle et conclure un contrat donnant accès à un environnement de test et à une documentation API versionnée.
- Configurer un KMS/HSM ou service de signature équivalent ; aucune clé privée dans Supabase public, Git, frontend ou base lisible par les utilisateurs.
- Vérifier dans Supabase les sauvegardes point-in-time, la rétention, la région, les journaux, les secrets Edge et les politiques Storage.
- Effectuer un test de restauration isolé et conserver le rapport.
- Exécuter les tests RLS avec deux entreprises réelles de test dans un projet non productif.

## Conditions avant toute déclaration positive

Les statuts `Certifié`, `Conforme NF`, `Homologué`, `Plateforme agréée` ou `Transmis à l'administration` sont interdits sans preuve officielle correspondante. L'interface doit rester sur `Architecture de conformité en cours de mise en place`, `À vérifier`, `Non configuré` ou `Validation externe requise` selon l'état réel.
