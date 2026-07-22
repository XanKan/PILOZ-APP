# Phase 8 — RGPD, sécurité et transparence

## Livré

- Cartographie des données, matrice de conservation, procédure de droits, registre préparatoire des sous-traitants et mesures de sécurité.
- Rôles métier explicites et fonction de permission serveur.
- Journalisation des changements de rôle et blocage des mutations du propriétaire sans procédure dédiée.
- Registres RLS pour preuves de conformité, anomalies, résolutions, demandes de droits, décisions, rétention et certifications.
- Registre de certifications volontairement vide; aucun badge positif n’est créé par défaut.
- Contrôle d’intégrité qui ouvre une anomalie critique append-only lorsque la chaîne ou une archive échoue.
- Évaluation et activation fiscale contrôlées. Le mode production exige identité, séquences, chaîne valide, absence d’anomalie critique, preuves vérifiées, KMS et profil électronique officiel vérifié.
- Écrans administrateur « Conformité et fiscalité » et « À propos et conformité » sans affirmation de certification.

## Non livré ou non activé

- Exécution des migrations dans le Supabase de production.
- Validation juridique des bases légales et durées.
- Suppression/anonymisation automatisée: elle reste bloquée jusqu’à validation juridique et test de restauration.
- KMS, signature, restauration vérifiée, profil officiel UBL/CII/Factur-X et plateforme agréée réels.
- Audit externe ou certification NF 525/NF 203.

## Principe d’affichage

Une absence de preuve est affichée comme un prérequis manquant. Les modes « legacy », « test », « unsigned », « not configured » et « non vérifié » restent visibles; l’interface ne les transforme pas en succès.

