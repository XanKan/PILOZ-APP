# Analyse initiale des écarts de conformité

Date de l'audit : 22 juillet 2026  
Périmètre : dépôt `PILOZ-APP`, branche `main`, commit initial `a13d4a9`  
Nature : audit technique interne préalable, sans valeur de certification ni d'avis juridique.

## Conclusion exécutive

Piloz possède déjà un socle utile : isolation logique par `company_id`, RLS déclarées dans les migrations, séquences PostgreSQL verrouillées, sauvegarde atomique des documents, finalisation transactionnelle des factures, instantanés, génération PDF serveur, protection des factures finalisées et RPC de paiements. Le test PostgreSQL embarqué confirme le parcours devis → facture et l'attribution du numéro de facture à la finalisation.

Ce socle ne permet toutefois pas de déclarer Piloz conforme ou certifié. Les écarts les plus critiques sont l'absence de journal fiscal append-only chaîné, de registre d'encaissements par événements inverses, de clôtures et d'archives fiscales vérifiables, de gestion de clés, de modèle canonique de facture électronique validé, de connecteur réel de plateforme agréée et de système qualité auditable. Des chemins de secours du frontend permettent aussi encore des écritures CRUD directes sur des données sensibles si une RPC manque.

## Méthode et limites

- `git status`, `git remote -v` et `git pull --rebase origin main` exécutés avant modification ; dépôt propre et synchronisé.
- Analyse statique des 38 migrations, 8 Edge Functions, modules JavaScript, tests et historique Git.
- Test `tests/document-lifecycle-pglite.cjs` exécuté avec toutes les migrations : succès.
- Aucun texte intégral NF 525, NF 203, XP Z12-012, XP Z12-013 ou XP Z12-014 n'est présent dans le dépôt.
- Les pages catalogue AFNOR permettent d'identifier les éditions XP de juin 2026, mais pas d'affirmer la couverture de clauses non consultées.
- La CLI Supabase n'est pas installée/liée sur ce poste. L'état réellement appliqué en production, les sauvegardes du projet, les secrets, les RLS effectives et les journaux de production restent à vérifier dans l'administration Supabase.
- Aucune plateforme agréée, aucun contrat API et aucun KMS ne sont fournis.

## Référentiels consultés

| Référentiel | Texte dans le dépôt | Édition identifiée | Clauses consultées | Exigences confirmées | Statut |
|---|---:|---|---|---|---|
| NF 525 | Non | Référentiel de certification à obtenir auprès d'AFNOR/INFOCERT | Aucune clause normative | Seulement le périmètre public : inaltérabilité, sécurisation, conservation, archivage | À valider avec le référentiel officiel |
| NF 203 | Non | Référentiel de certification à obtenir auprès d'AFNOR/INFOCERT | Aucune clause normative | Seulement les caractéristiques publiques de la démarche NF Logiciel | À valider avec le référentiel officiel |
| XP Z12-012 | Non | Juin 2026, en vigueur | Aucune clause normative | Titre, objet général, date et statut issus du catalogue AFNOR | À valider avec le référentiel officiel |
| XP Z12-013 | Non | Juin 2026, en vigueur | Aucune clause normative | Titre, objet général, date et statut issus du catalogue AFNOR | À valider avec le référentiel officiel |
| XP Z12-014 | Non | Juin 2026, en vigueur | Aucune clause normative | Titre, objet général, date et statut issus du catalogue AFNOR | À valider avec le référentiel officiel |

Sources publiques consultées : [mentions obligatoires d'une facture](https://www.economie.gouv.fr/entreprises/gerer-son-entreprise-au-quotidien/gerer-sa-comptabilite-et-ses-demarches/mentions-obligatoires-dune-facture-tout-savoir), [facturation électronique et plateformes agréées](https://www.impots.gouv.fr/facturation-electronique-et-plateformes-agreees), [article 286 du CGI](https://www.legifrance.gouv.fr/codes/article_lc/LEGIARTI000034309494/2018-01-01), [durées de conservation](https://www.cnil.fr/fr/passer-laction/les-durees-de-conservation-des-donnees). La version juridique applicable doit être confirmée au jour de l'audit externe.

## Architecture observée

| Domaine | Implémentation observée | Évaluation initiale |
|---|---|---|
| Frontend | Site statique GitHub Pages, routeur par fragments, modules IIFE, clé publique Supabase | Partiellement conforme |
| Multi-entreprise | `company_id`, fonctions d'appartenance, RLS déclarées | Partiellement conforme ; production à contrôler |
| Numérotation | `document_sequences`, verrou `FOR UPDATE`, RPC `_piloz_take_document_number` | Partiellement conforme ; journal d'attribution absent |
| Brouillons | RPC `save_document_draft` avec lignes dans une transaction | Conforme techniquement au périmètre testé |
| Finalisation | RPC `finalize_document`, numéro, verrou, snapshot, tâche PDF | Partiellement conforme ; validation légale et preuve cryptographique incomplètes |
| Factures finalisées | Triggers de protection sur document/lignes, snapshot immuable | Partiellement conforme ; chemins privilégiés et production à contrôler |
| Avoirs | RPC de création et liaison à la facture | Partiellement conforme ; couverture partielle/TVA à élargir |
| Paiements | RPC d'enregistrement/annulation et protection des paiements confirmés | Non conforme à la cible : annulation par mutation de statut, pas par écriture inverse |
| Journal | `activity_logs`, mutable et non chaîné | Non conforme à la cible fiscale |
| Clôtures | Absentes | Non conforme |
| Archives fiscales | Absentes | Non conforme |
| Cryptographie | SHA-256 de snapshot/PDF ; aucune signature/KMS | Partiellement conforme |
| PDF | Génération Edge, Storage privé, instantané | Partiellement conforme ; preuve hors application absente |
| E-invoicing | Aucun modèle canonique ni validateur officiel | Non conforme / en préparation |
| Plateforme agréée | Aucun connecteur réel | Non configuré |
| Qualité | Tests navigateur, pgTAP et PGlite ; documentation initiale | Partiellement conforme à une préparation NF 203 |
| RGPD | RLS et stockage privé ; pas de registre de demandes ni matrice complète | Partiellement conforme |

## Parcours critiques reproduits

| Parcours | Résultat | Preuve |
|---|---|---|
| Création d'un devis | Réussite | `tests/document-lifecycle-pglite.cjs` |
| Modification du devis avant facturation | Réussite | même test |
| Conversion devis → facture | Réussite | même test |
| Verrouillage du devis après conversion | Réussite | même test |
| Création d'une facture brouillon sans numéro officiel | Réussite | même test |
| Finalisation et numéro atomique | Réussite | même test |
| Modification d'une facture finalisée | Protégée par triggers dans les migrations | Test négatif à compléter |
| Paiement partiel/total | RPC présentes | Tests métier à étendre |
| Avoir total/partiel | RPC présentes | Test complet à étendre |
| Export | PDF Edge présent | Archive fiscale absente |

## Écritures navigateur à supprimer ou encadrer

1. `assets/js/modules/erp/erp-app.js` contient un fallback de sauvegarde qui modifie directement `documents`, supprime puis recrée `document_lines` si `save_document_draft` est absente.
2. Le même module contient des fallbacks de statut qui modifient directement `documents` si `transition_document_status` est absente.
3. Les paramètres et l'onboarding effectuent des upserts directs dans `document_sequences` ; la valeur suivante ne doit pas être modifiable depuis le navigateur après activation fiscale.
4. `assets/js/modules/erp/erp-modern.js` crée directement les factures fournisseurs et leurs lignes. Ce flux n'est pas une facture de vente, mais doit être séparé explicitement du domaine fiscal émetteur.
5. Des relances et métadonnées commerciales mettent à jour directement un document ; les colonnes non fiscales doivent être séparées des instantanés fiscalisés.

## Écarts par statut demandé

### Conforme techniquement

- Réponse API robuste : gestion des corps vides, du type de contenu et du JSON invalide.
- Numérotation SQL protégée contre la concurrence dans le chemin RPC testé.
- Brouillon de facture sans numéro officiel, puis numéro lors de la finalisation.
- Totaux recalculés par des fonctions PostgreSQL lors de la sauvegarde/finalisation.
- CNAME GitHub Pages intact.

### Partiellement conforme

- Mentions légales, validations et règles fiscales conditionnelles.
- Finalisation, verrouillage, snapshot et PDF final.
- Avoirs, paiements, rôles, RLS, stockage privé, traçabilité applicative.
- Gestion des versions et tests automatisés.

### Non conforme à l'architecture cible

- Journal fiscal append-only chaîné et signé.
- Événements d'encaissement correctifs sans mutation de l'original.
- Clôtures journalières, mensuelles et annuelles.
- Archives fiscales avec manifeste et vérification hors application.
- KMS, rotation et vérification des signatures.
- Modèle canonique et exports UBL/CII/Factur-X validés par artefacts officiels.
- Connecteur de plateforme agréée et e-reporting réels.
- Dossier de preuves générable et système qualité complet.

### Non applicable à ce stade

- Transmission réelle à l'administration : Piloz n'est pas une plateforme agréée et aucun connecteur contractuel n'est configuré.
- Affichage d'une certification : aucun certificat réel n'est enregistré.

### À confirmer juridiquement

- Applicabilité exacte de l'article 286 du CGI au périmètre fonctionnel et aux populations clientes de Piloz.
- Mentions conditionnelles, conservation, purge/anonymisation et calendrier par catégorie d'entreprise.
- Politique d'avoirs, corrections et statuts selon les cas métier.

### À confirmer avec AFNOR

- Toutes les exigences détaillées NF 525, NF 203 et XP Z12-012/-013/-014.
- Niveaux de clôture, canonicalisation, signature, exports et cas d'usage attendus.

### À confirmer avec un organisme certificateur

- Périmètre produit et versions couvertes.
- Choix cryptographiques/KMS, chaîne de preuve, procédure d'activation et traitement des données antérieures.
- Processus qualité, surveillance, support, gestion des incidents et dossier de preuves.

## Décision de sécurité immédiate

Le nouveau moteur doit être livré désactivé par défaut. Son activation de production sera refusée tant que les migrations, les séquences, les données entreprise, les tests, les sauvegardes, le KMS et la revue externe requise ne sont pas attestés. Les données antérieures resteront marquées `legacy_unsecured` et ne recevront aucune fausse signature rétroactive.
