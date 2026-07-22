# Guide utilisateur — opérations fiscales

Version couverte : `0.9.0-compliance.2` (pré-release).

## Brouillon et finalisation

Une facture brouillon reste modifiable et ne reçoit pas de numéro fiscal officiel. « Finaliser » demande au serveur de recharger les données, valider les mentions, recalculer les montants, attribuer le numéro, créer l’instantané et verrouiller la facture. Une facture finalisée ne se corrige jamais en réécrivant ses champs.

Les devis suivent leur cycle commercial et restent modifiables jusqu’à leur conversion selon les règles de l’application. Leur numéro ne doit pas être confondu avec une séquence de facture.

## Corriger une facture

Utiliser un avoir total ou partiel relié à la facture d’origine. Si une nouvelle facture est nécessaire, conserver le lien entre l’avoir, l’original et la nouvelle pièce. Ne jamais supprimer ou remplacer silencieusement la facture finalisée ou son PDF.

## Paiements

Un paiement total ou partiel ajoute une écriture au registre. Une erreur est annulée par une écriture inverse motivée; l’écriture initiale reste visible. Le solde de la facture est recalculé depuis le registre. Les rôles Lecture seule, Commercial et Auditeur ne peuvent pas enregistrer un encaissement par défaut.

## Clôtures et archives

Une clôture fige les totaux et les empreintes d’une période. Une archive regroupe données structurées, PDF disponibles, événements, clôtures et manifeste. Elles sont immuables. Dans cette pré-release, leur signature reste explicitement `unsigned` tant qu’un KMS validé n’est pas configuré.

Le script `verify-fiscal-archive` contrôle les empreintes et la chaîne hors de l’application. Sans clé et certificat validés, il ne peut pas confirmer une signature cryptographique.

## Export et dossier de preuves

Le dossier de preuves rassemble version, migrations, contrôles et documentation. Il doit être généré sur des données synthétiques ou minimisées et ne doit contenir ni jeton, ni clé privée, ni IBAN complet, ni vraie donnée client inutile.

## Facturation électronique

Un PDF seul n’est pas une facture électronique structurée au sens de la réforme. Piloz dispose d’un modèle canonique interne; les exports UBL, CII et Factur-X restent volontairement bloqués sans profil officiel et validation XSD/Schematron. La transmission réelle reste bloquée sans plateforme agréée configurée. Le sandbox indique toujours qu’il s’agit d’une simulation.

## Erreur de transmission

Conserver le document et son état commercial. Consulter le statut technique, l’erreur et la dead-letter queue; corriger la configuration ou les données puis relancer avec la même clé d’idempotence. Ne jamais transformer une simulation ou un échec en statut « transmis ».

## Conformité

L’écran Paramètres → Conformité et fiscalité montre les preuves présentes et les prérequis manquants. « Codé », « testé » ou « opérationnel techniquement » ne signifie pas « certifié ». Seules des certifications réelles, enregistrées avec leur preuve et vérifiées, peuvent apparaître dans Paramètres → À propos et conformité.

