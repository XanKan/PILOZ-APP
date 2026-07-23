# Procédure d’activation de Piloz

Cette procédure sépare le déploiement technique, réalisable maintenant, des validations qui exigent un accès Supabase, un prestataire ou une décision juridique. Elle ne constitue ni une certification NF 525/NF 203, ni une validation AFNOR, ni une homologation de facturation électronique.

## 1. Ce que vous devez préparer

Dans Supabase, vérifiez d’abord qu’une sauvegarde exploitable existe et notez sa date. Si votre offre le permet, vérifiez aussi le point-in-time recovery. Ne lancez pas `-Apply` sans cette vérification.

Récupérez ensuite :

- un Personal Access Token Supabase depuis les paramètres de votre compte ;
- le mot de passe PostgreSQL du projet ;
- la référence du projet, normalement `hpxcbemezvynofxiffzs`.

Ne copiez aucune de ces valeurs dans Git, dans un fichier `.env` suivi ou dans le navigateur.

## 2. Prévisualiser sans modifier Supabase

Ouvrez PowerShell dans `C:\Users\Quentin\Documents\PILOZ\PILOZ-APP`, puis exécutez :

```powershell
$env:SUPABASE_ACCESS_TOKEN="VOTRE_TOKEN_PERSONNEL"
$env:SUPABASE_DB_PASSWORD="VOTRE_MOT_DE_PASSE_POSTGRES"
.\scripts\deploy-supabase-production.ps1
```

Le script vérifie le dépôt, le CNAME, la release, synchronise `main`, lie le projet et exécute uniquement `db push --dry-run`. Il ne demande pas de saisir `y`, ce qui évite l’erreur `NonInteractiveError`.

Vérifiez que la liste se termine par `202607230050_catalog_workspace.sql` et qu’aucune migration inattendue n’est annoncée.

## 3. Appliquer les migrations et déployer les Edge Functions

Après confirmation de la sauvegarde :

```powershell
.\scripts\deploy-supabase-production.ps1 -Apply -BackupConfirmed
```

Le script applique les migrations additives avec la version épinglée `2.109.1` du CLI Supabase, lance le lint distant, déploie toutes les Edge Functions puis affiche l’historique des migrations. Il n’exécute jamais `db reset`, `push --force` ou une suppression de données.

Dans Supabase > SQL Editor, ouvrez et exécutez ensuite le contenu de `scripts/post-deploy-production-checks.sql`. Le JSON rendu doit contenir :

```json
{"ok": true, "schema_version": "202607230050"}
```

Conservez ce résultat daté dans votre dossier de preuves, sans donnée client ni secret.

## 4. Activer les clôtures planifiées

Dans Piloz, connectez-vous comme propriétaire puis ouvrez `Paramètres > Conformité et fiscalité`. Cliquez sur `Activer les clôtures`. Cette action active la détection journalière, mensuelle et annuelle ; elle n’active pas les archives signées.

Dans Supabase > Cron > Jobs, créez ensuite un job :

- nom : `piloz-fiscal-maintenance-daily` ;
- horaire : `15 2 * * *` ;
- type : SQL snippet ;
- commande :

```sql
select public.run_due_fiscal_maintenance(clock_timestamp());
```

Le moteur recherche les périodes closes avec activité et ignore les périodes déjà clôturées. Contrôlez l’historique du job le lendemain, puis l’écran de conformité. Le réglage de fuseau utilisé par Piloz est `Europe/Paris` ; l’horaire Cron est interprété par l’infrastructure Supabase.

## 5. Vérifications fonctionnelles à faire avec votre compte

Effectuez dans l’ordre :

1. créer un devis avec plusieurs lignes, l’enregistrer puis ouvrir son PDF ;
2. convertir ce devis en facture ;
3. vérifier que le brouillon de facture n’a pas de numéro légal ;
4. finaliser la facture et vérifier le numéro, le PDF et le verrouillage ;
5. enregistrer un paiement partiel, puis le solde ;
6. enregistrer un trop-perçu de test, puis le rembourser en deux écritures partielles ;
7. confirmer que l’écriture initiale reste visible et non modifiable ;
8. créer une demande RGPD de test dans l’écran de conformité, confirmer l’identité, exporter puis clôturer ;
9. lancer un contrôle d’intégrité et vérifier qu’aucune anomalie critique n’est créée ;
10. vérifier avec un second compte d’une autre entreprise qu’aucune donnée n’est visible entre les deux sociétés.

Utilisez uniquement des données de test pour les étapes 6, 8 et 10.

## 6. Actions externes qui restent obligatoires

Ces actions ne peuvent pas être réalisées automatiquement depuis le dépôt :

- faire relire les mentions, règles de TVA, avoirs, remboursements et durées de conservation par un conseil juridique/DPO ;
- obtenir légalement les référentiels NF 525, NF 203 et XP Z12-012/-013/-014, puis compléter la matrice sans inventer de clause ;
- choisir et contractualiser un KMS/HSM, faire valider l’algorithme, la rotation, la révocation et les clés publiques ;
- choisir une plateforme agréée figurant sur la liste officielle, obtenir son contrat API et son bac à sable ;
- installer les artefacts officiels UBL/CII/Factur-X et exécuter leurs validateurs ;
- effectuer une restauration réelle dans un environnement isolé et conserver le rapport ;
- organiser un test d’intrusion, une revue RLS de production et l’audit/certification visé.

Tant que ces preuves ne sont pas enregistrées et vérifiées, laissez le moteur fiscal en mode `off` ou `test`. Ne cliquez pas sur l’activation production et ne présentez pas Piloz comme certifié ou conforme.

## 7. Nettoyer les secrets de la session PowerShell

Quand le déploiement est terminé :

```powershell
Remove-Item Env:SUPABASE_ACCESS_TOKEN
Remove-Item Env:SUPABASE_DB_PASSWORD
```

Les commandes officielles utilisées suivent la documentation Supabase : liaison par `--project-ref`, mot de passe via `SUPABASE_DB_PASSWORD`, aperçu `db push --dry-run`, déploiement `functions deploy` et planification via Cron.
