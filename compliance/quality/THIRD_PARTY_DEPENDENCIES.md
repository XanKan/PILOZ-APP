# Dépendances tierces

| Composant | Version/référence | Usage | Risque/action |
|---|---|---|---|
| Supabase JS | `npm:@supabase/supabase-js@2` | Auth, REST, Storage, Functions | Version majeure non verrouillée : figer et surveiller |
| pdf-lib | `1.17.1` | PDF serveur | Surveiller vulnérabilités et reproductibilité |
| sanitize-html | `2.17.0` | Contenu modèles/e-mails | Conserver tests XSS et mises à jour |
| Chart.js | `4.4.1` CDN | Graphiques | SRI/auto-hébergement à évaluer |
| SheetJS xlsx | `0.18.5` CDN | Imports/exports | SRI, vulnérabilités et données non fiables |
| Google Fonts | service distant | Typographie | RGPD/CSP et auto-hébergement à évaluer |
| PGlite | installé uniquement en CI/test | Tests migrations | Figer la version dans la CI |
| GitHub Pages | service | Frontend/DNS | Continuité, intégrité du déploiement |
| Supabase | service | Base/Auth/Storage/Functions | Contrat, région, backups, DPA, disponibilité |
| Resend/Twilio | optionnels | E-mail/SMS | Sous-traitants, secrets, DPA, absence gérée |
| APIs publiques françaises | endpoints documentés | Entreprises/adresses | Disponibilité, finalité, minimisation |

Un SBOM automatisé, des versions verrouillées, une CSP/SRI et une revue de licences sont encore nécessaires. La liste doit être revue à chaque release.
