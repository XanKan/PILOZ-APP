# Rapport de migration — Thèmes de documents

Date : 25 juillet 2026
Migration : `202607250059_document_themes.sql`
Renderer : `theme-renderer-v1`

## Résultat

L’ancien système de modèles n’est pas supprimé. `document_templates` reste l’identité stable d’un modèle et est présenté comme un thème dans l’interface. `document_template_versions` conserve chaque enregistrement sous forme d’une nouvelle version immuable.

La configuration canonique comprend la structure, le logo, les couleurs, les typographies, le tableau, la décoration, le pied de page, les marges, les liens et les assignations. Les anciennes colonnes restent remplies pour la compatibilité.

## Données migrées

- les identifiants de modèles existants sont conservés ;
- les réglages historiques sont normalisés dans `configuration_json` ;
- la configuration courante alimente la miniature durable `thumbnail_config` ;
- les paramètres de devis et facture par défaut deviennent des assignations de thèmes ;
- les brouillons reçoivent `theme_id` et `theme_version` ;
- les documents déjà finalisés, leurs snapshots et leurs PDF ne sont pas réécrits ;
- trois thèmes système distincts sont ajoutés : Classique, Moderne et Compact.

## Tables et colonnes ajoutées

- métadonnées de thème sur `document_templates` et `document_template_versions` ;
- `documents.theme_id`, `documents.theme_version`, `documents.theme_snapshot` ;
- `document_theme_assignments` ;
- `document_theme_assets` ;
- `document_theme_links` ;
- `document_theme_footer_logos` ;
- `document_theme_usage` ;
- `document_theme_user_preferences`.

## Sécurité

Toutes les nouvelles tables sont isolées par `company_id` et protégées par RLS. La lecture est réservée aux membres de l’entreprise. Les écritures nécessitent le rôle propriétaire/administrateur ou la permission `manage_document_themes`. Les préférences restent limitées à l’utilisateur concerné.

Les images sont stockées dans le bucket privé `company-assets`, sous `company_id/themes/theme_id/…`. Aucun secret ni URL publique permanente n’est enregistré dans la configuration.

## Immutabilité

Lors de la finalisation, la version exacte du thème, sa configuration, son checksum et les références d’assets sont copiés dans le snapshot du document. Une modification ultérieure du thème ne modifie donc ni le snapshot ni le PDF finalisé.

## Compatibilité PDF

Le générateur accepte les anciennes versions comme les nouvelles. Pour une nouvelle version, il lit `configuration_json`; pour une ancienne, il conserve le repli sur `layout_key`, `color_settings`, `logo_settings` et `visible_columns`.

Le filigrane `SPECIMEN` est généré uniquement par le renderer HTML de l’éditeur et n’est jamais ajouté au PDF métier.

## Contrôles exécutés avant déploiement

- application complète des migrations dans PGlite/PostgreSQL : réussie ;
- test dédié des thèmes : 143 assertions réussies, dont duplication des assets, réglages complets des logos de pied de page, assignations et isolation inter-entreprises ;
- test du cockpit sur le schéma complet : réussi ;
- validation syntaxique JavaScript : réussie ;
- bundle de la fonction PDF : réussi ;
- manifeste de release et CNAME : réussis.

## Action de production

La migration et la fonction Edge doivent être déployées avant d’utiliser l’écran en production :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\deploy-supabase-production.ps1 `
  -Apply `
  -BackupConfirmed

npx.cmd --yes supabase@2.109.1 functions deploy generate-document-pdf `
  --project-ref hpxcbemezvynofxiffzs
```

Puis exécuter `scripts/post-deploy-production-checks.sql` dans l’éditeur SQL Supabase. Le résultat attendu est `ok: true` et `schema_version: 202607250059`.
