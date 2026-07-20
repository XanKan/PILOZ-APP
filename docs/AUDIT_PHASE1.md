# Audit initial et architecture cible

## État initial observé

- application statique GitHub Pages concentrée principalement dans `index.html` ;
- navigation historique par fragments, à préserver pour la compatibilité d'hébergement ;
- accès Supabase directement depuis le navigateur avec la clé publique ;
- modèles et écrans métier historiques imbriqués dans le monolithe ;
- absence d'un socle SQL versionné couvrant l'ensemble de l'onboarding, du stock, des achats et des documents ;
- absence de tests locaux reproductibles pour les calculs et le rendu des routes ERP.

## Risques identifiés

- isolement multi-entreprises incomplet sans RLS uniforme ;
- numérotation concurrente et doubles mouvements de stock sans fonctions SQL atomiques ;
- exposition de secrets si les intégrations e-mail, SMS ou API sont appelées directement depuis le navigateur ;
- incohérence des totaux, réservations et coûts moyens si ces règles restent uniquement côté client ;
- HTML de modèles dangereux sans validation serveur ;
- perte de compatibilité GitHub Pages si les routes cessent d'utiliser les fragments.

## Architecture mise en place

- migrations Supabase ordonnées, RLS par `company_id`, journal d'activité et fonctions métier atomiques ;
- Edge Functions authentifiées pour les API officielles, les confirmations, l'e-mail et la sauvegarde sécurisée des modèles ;
- modules JavaScript séparés pour l'API, les calculs, l'onboarding et l'ERP ;
- stockage privé des logos et pièces jointes avec URL signées ;
- navigation ERP conservée sous forme de fragments `#...` ;
- tests navigateur pour les calculs et le rendu des routes, plus tests pgTAP structurels pour la base.

## API et services nécessaires

- API Recherche d'entreprises pour la raison sociale, le SIRET et les établissements ;
- service de géocodage de la Géoplateforme pour l'adresse prédictive ;
- Resend pour les confirmations et l'envoi de documents ;
- Twilio facultatif pour la vérification téléphonique ;
- Supabase Auth, PostgreSQL, Storage et Edge Functions.

## Découpage réalisé

1. fondation multi-entreprises et onboarding professionnel ;
2. clients, fournisseurs, catalogue, coûts, prix et marges ;
3. documents commerciaux et éditeur pleine page ;
4. modèles visuels/code, aperçu, assainissement et versions ;
5. entrepôts, emplacements, mouvements, réservations et inventaires ;
6. achats, réceptions, retours, réapprovisionnement et coût moyen ;
7. rapports, permissions, tests, responsive et documentation.

## Compatibilité et migration

Les migrations commencent par créer les structures manquantes, conservent les données historiques utilisables, puis ajoutent les domaines ERP. Les anciennes données d'entreprise ne sont marquées comme onboarding terminé que si les champs obligatoires sont réellement renseignés. Les fichiers publics restent déployables sur GitHub Pages et `CNAME` n'est pas modifié.
