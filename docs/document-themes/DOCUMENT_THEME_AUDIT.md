# Audit des thèmes de documents Piloz

Date de l'audit : 25 juillet 2026
Dépôt : `XanKan/PILOZ-APP`
Branche : `main`

## Périmètre analysé

- page actuelle `Modèles de documents` et éditeur associé ;
- éditeurs de devis, factures, acomptes, soldes et avoirs ;
- fonction Edge `save-document-template` ;
- fonction Edge `generate-document-pdf` ;
- migrations des modèles, documents, snapshots et fichiers ;
- politiques RLS et Storage ;
- préférences documentaires des clients ;
- tests de cycle documentaire et de rendu.

## Architecture actuelle

Piloz dispose déjà de deux tables adaptées au versionnement :

- `document_templates` porte l'identité mutable du modèle : entreprise, nom, type, statut, modèle par défaut et version courante ;
- `document_template_versions` porte les réglages historisés : mise en page, couleurs, logo, colonnes, en-têtes, pied de page, profils émetteur/client et moyens de paiement.

Les documents stockent actuellement `template_id`. À la création d'un aperçu, le générateur PDF résout la version courante du modèle. À la finalisation, `_piloz_create_document_snapshot` copie le modèle et sa version dans `document_snapshots.public_payload`. Le PDF final est généré depuis cet instantané, stocké dans le bucket privé `company-files`, puis associé au document avec son empreinte SHA-256. Les instantanés sont immuables.

Les logos d'entreprise sont stockés dans le bucket privé `company-assets` et référencés par `company_logos`. Les politiques Storage isolent les fichiers par le premier segment de chemin, qui est le `company_id`.

La fiche client possède déjà des préférences `quote_template_id` et `invoice_template_id`. Les paramètres de documents conservent les modèles de devis et de facture par défaut.

## Source de vérité retenue

Le socle existant est conservé et étendu :

1. `document_templates` reste l'identité canonique, présentée comme un **thème** dans l'interface ;
2. `document_template_versions.configuration_json` devient la représentation canonique `DocumentThemeConfiguration` ;
3. l'aperçu, la miniature et le PDF lisent cette même configuration versionnée ;
4. les colonnes historiques de `document_template_versions` restent renseignées pour la compatibilité avec les documents et versions antérieurs ;
5. un document finalisé conserve l'identité, le numéro de version et la configuration figée dans son snapshot.

Ce choix évite une duplication des modèles, conserve toutes les clés étrangères existantes et protège les documents déjà finalisés.

## Limites constatées

- la page actuelle est une table et non une bibliothèque de thèmes visuelle ;
- la création ne permet pas explicitement de partir d'un thème vierge ou existant ;
- seules les structures `classic`, `modern` et `compact` sont reconnues ;
- l'éditeur actuel n'offre pas les rubriques Décoration, Espacement, Liens, Assignation ou logos de pied de page ;
- les réglages sont répartis entre plusieurs colonnes JSON historiques sans contrat canonique unique ;
- les miniatures ne sont pas persistées comme représentation du rendu ;
- les types autres que devis/facture n'ont pas d'assignation indépendante ;
- la suppression directe d'un modèle n'exprime pas suffisamment la distinction entre archivage et suppression sûre ;
- le moteur PDF applique les réglages existants, mais pas encore tous les réglages demandés (polices, décorations, marges, ordre complet des colonnes et liens).

## Champs réutilisables

- identité : `document_templates.id`, `company_id`, `name`, `status`, `current_version`, auteurs et dates ;
- version : `layout_key`, `color_settings`, `logo_settings`, `visible_columns`, `header_fields`, `footer_id`, `document_title`, `client_profile`, `issuer_profile`, `payment_methods` ;
- documents : `documents.template_id`, `documents.metadata` et `document_snapshots.public_payload` ;
- pieds de page : `document_footers` ;
- assets : `company_logos`, `company-assets` et `company-files` ;
- assignations historiques : `company_document_settings` et préférences client.

## Données à migrer

La migration est additive et idempotente :

- chaque modèle existant devient un thème actif sans changement d'identifiant ;
- chaque version existante reçoit une `configuration_json` dérivée de ses colonnes historiques ;
- les modèles par défaut actuels deviennent les assignations par défaut des devis et factures ;
- aucun historique de version antérieur n'est inventé ;
- aucun document finalisé, snapshot ou PDF existant n'est modifié ;
- les nouveaux thèmes système Classique, Moderne et Compact ne sont ajoutés que lorsqu'ils n'existent pas déjà.

## Risques de divergence aperçu/PDF

1. **Police non disponible côté PDF** : seules les familles intégrées ou possédant une substitution serveur déterministe sont proposées.
2. **Pagination** : l'aperçu HTML et PDF partagent la configuration, mais le moteur PDF reste responsable de la pagination finale.
3. **Images externes** : seuls les assets Storage appartenant à l'entreprise sont acceptés.
4. **Configuration historique incomplète** : un normaliseur applique des valeurs par défaut déterministes sans réécrire les anciennes versions.
5. **Modification après finalisation** : le générateur final lit exclusivement le snapshot et jamais la version courante du thème.

## Thèmes déjà utilisés

Les migrations et tests confirment que des documents peuvent référencer `document_templates.id`, y compris des modèles personnalisés ajoutés par les utilisateurs. La migration ne supprime, ne fusionne et ne renumérote aucun de ces modèles. Une utilisation historique empêche la suppression physique du thème ; l'archivage reste possible.

## Stratégie de compatibilité

- conserver les tables et identifiants actuels ;
- ajouter les métadonnées de thème, la configuration canonique, les assignations et les assets spécialisés ;
- maintenir les colonnes historiques lors de chaque enregistrement ;
- faire accepter au générateur PDF les anciennes versions comme les nouvelles ;
- garder `template_id` comme alias de compatibilité dans les brouillons ;
- figer automatiquement la version et la configuration lors de la finalisation ;
- ne jamais régénérer silencieusement un PDF finalisé.

## Conclusion

Le système actuel n'a pas besoin d'être remplacé au niveau fiscal. Il doit être transformé en éditeur de thèmes en étendant le modèle versionné existant. Cette approche minimise le risque, conserve les données et permet d'aligner l'aperçu, les miniatures et le PDF autour d'un même contrat de configuration.
