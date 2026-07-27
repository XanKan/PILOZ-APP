# Changelog

## 0.9.0-compliance.50 — 27 juillet 2026

- ajoute la rubrique « Archives fiscales » à la Comptabilité pour toutes les entreprises, sans alourdir l’onboarding ;
- propose automatiquement le mois précédent et interdit l’archivage d’une période non terminée ;
- refuse depuis l’interface les archives incomplètes lorsque le PDF original d’une facture définitive manque ;
- enchaîne la création immuable, la signature AWS KMS, la vérification cryptographique et le téléchargement du paquet ;
- affiche le registre par période avec complétude, état de signature et dernier export ;
- documente les moments utiles : fin de mois, changement de logiciel, clôture importante et contrôle.

## 0.9.0-compliance.49 — 27 juillet 2026

- Ajoute un connecteur AWS KMS asymétrique serveur pour signer et vérifier les empreintes SHA-256 des archives fiscales.
- Enregistre les signatures dans un registre append-only isolé par entreprise, avec RLS et traçabilité fiscale.
- Signe automatiquement une archive au premier export lorsque le KMS est configuré et bloque l'export si une signature existante est invalide.
- Maintient honnêtement `kms_configured=false` dans le manifeste tant que la clé AWS et les secrets Supabase ne sont pas activés en production.

## 0.9.0-compliance.48 — 27 juillet 2026

- ajout de la recherche INPI dans la création rapide d’un client ou prospect depuis le pipeline, avec conservation des informations officielles sélectionnées ;
- remplacement du type visible « Service » par le véritable type d’élément « Main d’œuvre » dans le catalogue, les documents, les filtres, les imports, les exports et le paramétrage comptable ;
- conservation de la clé technique historique `service` uniquement en interne afin de préserver les fiches, factures et intégrations existantes ;
- normalisation des libellés API français et anglais vers les quatre types autorisés : Article, Main d’œuvre, Abonnement et Frais ;
- comptes de vente par défaut `707000`, `706000`, `706000` et `708000`, toujours modifiables par entreprise ;
- blocage des nouveaux pseudo-types Pack / Kit, Remise et Commentaire sans suppression des documents historiques ;
- contrôles automatisés des écrans, de l’API, des migrations, de l’agrégation comptable, des remises, des commentaires et des packs historiques.

## 0.9.0-compliance.47 — 27 juillet 2026

- refonte complète du suivi commercial autour de trois entrées claires : Pipeline, Activités et Rapports commerciaux ;
- déplacement des prospects dans la Bibliothèque avec redirection des anciennes routes et conservation des données ;
- pipeline commercial ramené à neuf étapes actives, avec migration non destructive des anciennes étapes et de leurs opportunités ;
- nouvelle modale centrée de création et modification des opportunités, recherche clients/prospects, création rapide et contacts associés ;
- calcul serveur canonique du montant des opportunités à partir des devis principaux et complémentaires actifs, tout en conservant l’estimation initiale ;
- qualification des liens documentaires (principal, variante, complément, remplacé) et conversion prospect-client sans recréer les opportunités ;
- menu d’actions complet sur les cartes et centre d’activités multi-vues relié aux clients, contacts, opportunités et documents ;
- rapports commerciaux agrégés côté serveur avec comparaison de période, prévisions, qualité du pipeline, activités, devis, sources, pertes et performance par collaborateur ;
- durcissement des droits lecture seule, de l’isolation par entreprise et ajout de tests statiques et PostgreSQL dédiés.

## 0.9.0-compliance.45 — 27 juillet 2026

- simplification des comptes de vente aux quatre types comptables Article, Service, Abonnement et Frais ;
- valeurs par défaut `707000`, `706000`, `706000` et `708000`, entièrement modifiables ;
- suppression des pseudo-types Pack / Kit, Remise et Commentaire du catalogue et du paramétrage comptable ;
- regroupement des montants HT par compte de vente, ventilation des remises sur les comptes concernés et exclusion des commentaires ;
- ventilation des packs historiques selon le type comptable de chacun de leurs composants ;
- contrôle bloquant des quatre comptes obligatoires avant la prévisualisation ou la validation d’un export comptable.

## 0.9.0-compliance.44 — 27 juillet 2026

- correction globale de la superposition des filtres au-dessus des tableaux ;
- calendriers de période, recherches client et panneau de colonnes placés dans une couche d’interface dédiée ;
- correction appliquée aux espaces documents, suivi commercial, clients, catalogue et comptabilité ;
- ajout d’un contrôle automatique empêchant la régression des niveaux de superposition.

## 0.9.0-compliance.43 — 27 juillet 2026

- correction de la cause résiduelle des exports `411 + auxiliaire` : les écritures non figées sont désormais remises en conformité avant chaque prévisualisation et validation ;
- garantie du format `CompteNum = 411NOMCLIENT`, `CompteLib = nom réel`, `CompAuxNum` et `CompAuxLib` vides dans le mode par défaut ;
- conservation durable du compte individualisé sur la fiche client et réutilisation pour ses factures, avoirs et règlements ;
- ajout d’une réconciliation automatique lors du changement de mode comptable, sans modifier les exports déjà validés ;
- ajout d’un test de régression reproduisant une ancienne ligne `411;Client - SOLUNEO;SOLUNEO;SOLUNEO` avant de vérifier sa correction à l’export.

## 0.9.0-compliance.42 — 27 juillet 2026

- remplacement du mode client `411 + auxiliaire` par le compte individualisé `411NOMCLIENT` directement dans `CompteNum` ;
- normalisation déterministe des noms (majuscules, accents, espaces, apostrophes, tirets et caractères spéciaux) et conservation durable du compte sur la fiche client ;
- colonnes `CompAuxNum` et `CompAuxLib` laissées vides dans le mode par défaut, avec `CompteLib` limité au nom réel du client sans préfixe ;
- conservation optionnelle de l’ancien mode collectif uniquement lorsqu’il est explicitement sélectionné dans le paramétrage comptable ;
- mise à niveau des écritures non exportées sans modifier les lots comptables déjà validés ;
- adaptation de la fiche client, de la prévisualisation, des contrôles de production et des tests factures, avoirs et règlements.

## 0.9.0-compliance.41 — 27 juillet 2026

- correction des droits du tableau de bord avec les permissions centrales `dashboard.read`, `catalog.margin.read`, paiements, CRM, catalogue et achats ;
- suppression de la régression où l’ancienne valeur par défaut `view_margins=false` masquait la marge d’un administrateur ;
- maintien d’un périmètre personnel pour les commerciaux et d’un périmètre entreprise pour les administrateurs, affiché clairement dans l’interface ;
- refonte complète du tableau de bord : accueil, filtres rapides, comparaison, actions, cartes KPI, boutons, états vides et personnalisation ;
- conservation du glisser-déposer, du redimensionnement, de la densité et des préférences enregistrées par utilisateur ;
- rafraîchissement des données ramené à 30 secondes et affichage de l’heure de dernière actualisation ;
- validation des calculs réels sur factures, avoirs, règlements et coûts, de l’isolation RLS, des performances et du responsive mobile.

## 0.9.0-compliance.40 — 27 juillet 2026

- correction du compte collectif client : les nouvelles écritures utilisent `411` au lieu de `411000` ;
- génération d’un compte auxiliaire client distinct, normalisé, unique et limité à 10 caractères maximum sans remplissage artificiel ;
- correction du repli qui supprimait l’auxiliaire lorsqu’aucun profil comptable spécifique n’existait ;
- conservation des exports déjà validés et mise à niveau des seules écritures encore exportables ;
- nouvelle prévisualisation comptable regroupée par pièce avec compte, auxiliaire, libellé, débit, crédit et totaux équilibrés ;
- ajout de la liste repliable des comptes, de l’impression et du contrôle automatisé `411 / CLIENT` dans les tests comptables.

## 0.9.0-compliance.39 — 26 juillet 2026

- rattrapage des factures définitives historiques qui ne possèdent pas encore d’écriture comptable, sans modifier les pièces d’origine ;
- génération comptable déclenchée sur toutes les transitions fiscales définitives et protégée contre les doublons ;
- diagnostic des exports vides distinguant période sans facture, écritures déjà exportées et pièces en erreur ;
- affichage d’un motif français exploitable lorsqu’une pièce ne peut pas être comptabilisée, avec détail technique limité à la console ;
- tests de non-régression couvrant une ancienne facture correctement rattrapée et une incohérence de TVA explicitement signalée.

## 0.9.0-compliance.29 — 26 juillet 2026

- ajout d’une confirmation explicite « Oui / Non » avant la validation d’un devis ;
- remplacement de la confirmation de facture par un formulaire de finalisation : date de facture du jour non modifiable, date de situation conditionnelle et date d’échéance sélectionnable ;
- contrôle visuel de la chronologie par rapport à la dernière facture définitive, en complément du verrou serveur déjà actif ;
- suppression des attentes PDF bloquantes et d’un rechargement complet redondant afin d’ouvrir la consultation plus rapidement, pendant que le PDF définitif se prépare en arrière-plan ;
- adoucissement du bandeau de navigation gauche avec un fond bleu nuit moins saturé et un état actif plus discret ;
- sécurisation de l’inscription après paiement : seul un événement Stripe signé et traité de façon idempotente ouvre le droit temporaire à l’onboarding ;
- ajout de la connexion Google et Microsoft via Supabase Auth, sans exposer de secret ni de jeton dans le navigateur ;
- ajout des Extensions Google Agenda, Outlook Calendar, Gmail et Outlook Mail avec OAuth PKCE, synchronisation incrémentale, webhooks, reprise sur erreur et périmètre personnel, partagé ou entreprise ;
- maintien honnête d’IMAP/SMTP et des connecteurs comptables propriétaires en état « À configurer » tant qu’aucun service serveur validé n’est disponible ;
- création d’une bibliothèque de CGV versionnées, importables en PDF, assignables par client et par type de document, puis figées avec les documents finalisés ;
- ajout du moteur de pré-comptabilité central équilibré, des journaux, exercices, comptes auxiliaires, règles de ventilation, écritures de règlements et exports figés ;
- ajout du registre des règlements, des exports ventes, achats et banque, de la TVA sur encaissements multi-taux et des contrôles de clôture fiscale ;
- distinction explicite entre les exports CSV génériques, le FEC technique à faire valider par un professionnel et les connecteurs propriétaires non activés ;
- isolation RLS par entreprise renforcée pour les connexions externes, messages, CGV, écritures et exports, avec coffre OAuth inaccessible au navigateur ;
- ajout des tests d’intégrité comptable, de TVA multi-taux, de clôture, d’isolation inter-entreprises et de non-divulgation des secrets.
- exclusion explicite de `app.piloz.fr` des moteurs de recherche via la balise `noindex, nofollow` et `robots.txt`, avec contrôle automatique avant publication ;
- ajout de la rubrique principale « Bibliothèque » regroupant Clients, Fournisseurs et Articles & services ;
- retrait temporaire de Stock de la navigation principale, sans suppression des données ni des fonctions existantes ;
- accès direct à « Créer un nouveau client » dès l’ouverture du sélecteur client des devis et factures ;
- suppression de l’ancien « aperçu figé » après l’enregistrement ou la validation : seul le PDF utilisant le modèle sélectionné peut désormais être affiché ;
- préparation du bon aperçu avant l’ouverture de la consultation d’un devis ou d’une facture ;
- blocage de la création d’une situation suivante lorsque l’avancement cumulé atteint 100 %, dans l’interface comme dans la fonction Supabase ;
- ouverture automatique de la consultation après finalisation d’une facture, d’un acompte, d’un solde ou d’une situation, sans écran intermédiaire de document verrouillé ;
- conservation du défilement de l’éditeur et du panneau droit après chaque recalcul (avancement, acompte, remise, TVA ou paramètre), sans retour intempestif en haut de page ;
- finalisation des factures d’acompte fiabilisée après un changement de régime TVA, y compris lorsque la valeur chargée provient d’un ancien format texte ;
- propagation correcte du mode silencieux lors de la sauvegarde préalable et remontée du véritable motif lorsqu’une finalisation est refusée ;
- alignement automatique des brouillons à 0 % de TVA lorsqu’une entreprise est déclarée non assujettie, afin d’autoriser leur finalisation sans produire de TVA incohérente ;
- masquage immédiat des paramètres TVA devenus inutiles lorsque l’assujettissement est désactivé ;
- simplification des listes de TVA dans les devis et factures : seuls les pourcentages configurés sont affichés ;
- affichage de la déduction d’acompte dans le récapitulatif des factures et des PDF ;
- choix de la déduction complète, au prorata de l’avancement ou d’un montant fixe sur les factures de situation ;
- calcul serveur autoritaire du montant net exigible avec conservation des totaux bruts et de la méthode choisie ;
- report automatique du solde d’acompte entre les situations successives ;
- ajout de CGV versionnées dans les modèles, limitées à 30 000 caractères et ajoutées automatiquement après le devis ou la facture ;
- génération multi-pages des CGV dans les aperçus et PDF définitifs.

## 0.9.0-compliance.28 — 26 juillet 2026

- conservation de la quantité contractuelle dans l’éditeur des factures de situation ;
- calcul du montant de la situation uniquement à partir du pourcentage d’avancement ;
- affichage cohérent de la quantité totale et de l’avancement dans l’aperçu intégré, les modèles et le PDF final ;
- compatibilité avec les anciennes situations grâce aux métadonnées de quantité d’origine déjà conservées.

## 0.9.0-compliance.27 — 26 juillet 2026

- réduction de l’indicateur d’avancement des factures de situation ;
- déplacement de la barre d’avancement dans l’en-tête, immédiatement à côté de « Plus d’actions » ;
- conservation du pourcentage réalisé et du reste à avancer dans ce format compact.

## 0.9.0-compliance.26 — 26 juillet 2026

- rétablissement de la finalisation directe depuis la fiche d’une facture brouillon ;
- maintien du modèle configuré dans la visionneuse pendant la génération du PDF définitif ;
- parcours acompte sécurisé : l’acompte prévu doit être finalisé avant une facture classique ou de situation ;
- possibilité de poursuivre après l’acompte par une facture de solde ou une facture de situation ;
- récapitulatif du marché dans les nouvelles factures liées et contrôle du plafond total facturé par rapport au devis.

## 0.9.0-compliance.25 — 26 juillet 2026

- validation complète des mentions obligatoires avant finalisation d’une facture, avec contrôles renforcés au 1er septembre 2026 ;
- verrouillage irréversible des données d’une facture définitive et correction exclusivement par avoir ;
- numérotation fiscale continue, unique et chronologique, avec contrôle de chronologie par séquence ;
- conservation légale sur dix ans des factures, instantanés, PDF et justificatifs verrouillés, avec empreintes d’intégrité ;
- piste d’audit reliant documents, paiements, pièces jointes, événements fiscaux et cycle de facturation électronique ;
- préparation facturation électronique et e-reporting avec calendrier d’obligation et contrôle d’aptitude honnête ;
- registre RGPD des violations, accords de sous-traitance et contrôles de sécurité/sauvegarde ;
- ajout des champs date de vente ou prestation, nature de l’opération, bon de commande et référence de contrat dans l’éditeur et le PDF ;
- écran Conformité enrichi et tests couvrant archivage, immutabilité, audit, RGPD et préparation e-facturation.

## 0.9.0-compliance.24 — 25 juillet 2026

- suppression immédiate de l’ancien aperçu PDF après l’enregistrement d’un devis ou d’une facture brouillon ;
- invalidation du rendu précédent avant et après la finalisation afin que le modèle configuré soit utilisé sans affichage transitoire de l’ancien modèle ;
- protection contre les générations PDF déjà en cours : une réponse obsolète ne peut plus réinjecter un ancien aperçu dans la visionneuse ;
- nouvelle version des ressources JavaScript pour forcer leur rechargement en production.

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
## 0.9.0-compliance.31 — 26 juillet 2026

- restauration immédiate de l’affichage des devis et factures sans perte de données ;
- ajout du droit de lecture manquant sur les CGV sélectionnées et d’un chargement de secours explicite ;
- correction de l’état actif de la navigation : les consultations et éditions de documents sélectionnent désormais Ventes.

## 0.9.0-compliance.30 — 26 juillet 2026

- nouveau Suivi commercial : multi-pipeline, vues Kanban/liste/prévision/calendrier et fiches détaillées ;
- prospects, contacts, import CSV, fusion anti-doublon, scoring et recherche globale ;
- activités replanifiables, boîte de réception CRM réelle et vues enregistrées ;
- automatisations avec journal et retry transactionnel, séquences, rapports filtrables et Command Center relié aux données Supabase ;
- migrations additives 077 à 079 avec RLS granulaire et isolation des messageries personnelles.
- validation de charge sur 100 000 prospects, 50 000 opportunités et 500 000 activités.
