# Activation des dépendances externes de production

Ce document décrit les opérations qui ne peuvent pas être réalisées par un commit Git. Ne placez jamais un secret OAuth, une clé de plateforme agréée ou une clé privée KMS dans le navigateur, Git ou une table lisible par les utilisateurs.

## Connexion Google

1. Dans Google Cloud Console, créez ou sélectionnez le projet Piloz et configurez l'écran de consentement OAuth.
2. Créez un identifiant OAuth 2.0 de type **Application Web**.
3. Ajoutez l'URI de redirection autorisée exacte : `https://hpxcbemezvynofxiffzs.supabase.co/auth/v1/callback`.
4. Dans Supabase > Authentication > Providers > Google, activez le fournisseur et renseignez le Client ID et le Client Secret.
5. Dans Supabase > Authentication > URL Configuration, utilisez `https://app.piloz.fr` comme Site URL et autorisez `https://app.piloz.fr/**`.
6. Testez un compte sans licence puis un compte avec licence : la garde de licence Piloz doit refuser le premier et ouvrir le tableau de bord du second.

## Connexion Microsoft

1. Dans Microsoft Entra ID > App registrations, créez l'application Piloz.
2. Pour un SaaS commercial, choisissez les types de comptes réellement pris en charge par Piloz (organisations uniquement, ou organisations et comptes Microsoft personnels).
3. Ajoutez une plateforme **Web** avec l'URI `https://hpxcbemezvynofxiffzs.supabase.co/auth/v1/callback`.
4. Créez un secret client, puis activez Azure dans Supabase > Authentication > Providers avec l'identifiant d'application et le secret.
5. Conservez les portées minimales `openid email profile offline_access` et testez la même garde de licence que pour Google.

Tant qu'un fournisseur n'est pas activé par Supabase, Piloz ne montre plus son bouton. L'e-mail et le mot de passe restent disponibles.

## Facturation électronique

Le modèle canonique, l'outbox, les contrôles et le connecteur serveur Piloz sont une fondation, pas une transmission réglementaire active. Pour passer en production :

1. contractualisez avec une plateforme agréée figurant sur la liste officielle ;
2. obtenez son environnement de test, sa documentation API et ses secrets serveur ;
3. choisissez les profils normatifs réellement acceptés (Factur-X, UBL ou CII) et leurs versions ;
4. installez les XSD/Schematron officiels, conservez leurs empreintes et exécutez les validateurs officiels ;
5. implémentez l'adaptateur du fournisseur dans la fonction serveur `platform-connector`, sans exposer le secret au navigateur ;
6. testez émission, réception, rejet, correction, doublon, reprise et e-reporting dans le bac à sable ;
7. faites valider les preuves, puis seulement mettez à jour `compliance/RELEASE_MANIFEST.json` avec les références réelles.

Références : [Ministère de l'Économie](https://www.economie.gouv.fr/tout-savoir-sur-la-facturation-electronique-pour-les-entreprises), [AIFE](https://aife.economie.gouv.fr/nos-applications/facturation-electronique-b2b/).

## Signature KMS des archives

1. choisissez AWS KMS, Google Cloud KMS, Azure Key Vault Managed HSM ou un service qualifié adapté après revue sécurité ;
2. créez une clé asymétrique de signature dans le KMS, avec rotation, révocation, journalisation et séparation des rôles ;
3. autorisez uniquement la fonction Edge d'archivage à demander une signature ; la clé privée ne doit jamais être exportable ;
4. implémentez `FiscalSigner` dans `supabase/functions/_shared/fiscal-crypto.ts` avec l'API du KMS ;
5. stockez l'identifiant de clé, l'algorithme, la signature, l'horodatage et les éléments publics de vérification ;
6. vérifiez une archive hors de Piloz et documentez un exercice de rotation/révocation ;
7. activez le drapeau KMS du manifeste uniquement après ce test externe.

## Certification et statut de commercialisation

Ne remplacez pas `pre-release` par une déclaration de conformité sur la seule base des tests internes. Définissez d'abord le périmètre d'encaissement concerné, faites réaliser l'audit juridique et fiscal, puis engagez l'organisme certificateur correspondant au périmètre retenu. Conservez le rapport, le certificat et sa portée. La doctrine fiscale française distingue la fonction de caisse des autres fonctions d'un logiciel multifonction : [DGFiP](https://www.impots.gouv.fr/professionnel/questions/quel-est-le-champ-dapplication-de-lobligation-de-detenir-un-logiciel-de).

## En-têtes HTTP avec GitHub Pages

Le HTML contient maintenant une CSP de secours et une politique de référent. GitHub Pages ne permet pas de définir tous les en-têtes de réponse. Pour obtenir la protection complète, placez `app.piloz.fr` derrière un proxy contrôlé (par exemple Cloudflare) et ajoutez :

```text
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https: wss:; frame-src 'self' data: blob: https:; worker-src 'self' blob:; media-src 'self' blob: https:; object-src 'none'; base-uri 'self'; form-action 'self' https://*.supabase.co; frame-ancestors 'none'; upgrade-insecure-requests
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```

Testez d'abord cette règle sur un sous-domaine de préproduction : une CSP trop restrictive peut bloquer Supabase, le PDF, Stripe ou les polices. Après activation, contrôlez les en-têtes avec `curl.exe -I https://app.piloz.fr`.
