# Cartographie des données personnelles

État : base de travail technique au 22 juillet 2026. Les bases légales, durées et rôles RGPD doivent être validés par le responsable de traitement et son conseil. Ce document ne constitue pas un registre juridique achevé.

| Catégorie | Tables / stockage | Personnes | Finalité prévue | Base à valider | Sensibilité | Accès applicatif |
|---|---|---|---|---|---|---|
| Comptes et habilitations | `auth.users`, `profiles`, `company_members` | utilisateurs | authentification, sécurité, administration | contrat / intérêt légitime | élevée | propriétaire, administrateur ; journal fiscal pour les changements |
| Clients et contacts | `clients`, `client_contacts`, `client_addresses`, `client_preferences` | clients, prospects, contacts | relation commerciale, devis, facturation | contrat / mesures précontractuelles / intérêt légitime | courante | vente, facturation, administration selon rôle |
| Prospects et CRM | `prospects`, `opportunities`, `activities`, `reminders`, notes | prospects, interlocuteurs | prospection et suivi commercial | consentement ou intérêt légitime à qualifier | courante | vente et administration |
| Fournisseurs | `suppliers`, commandes, réceptions | contacts fournisseurs | achats et exécution contractuelle | contrat / obligation comptable | courante | achats, comptabilité, administration |
| Documents commerciaux | `documents`, lignes, snapshots, PDF, pièces jointes | clients, contacts | devis, factures, avoirs, preuve contractuelle | contrat / obligation légale | potentiellement élevée | rôles métier ; pièces finalisées immuables |
| Paiements | `payments`, échéanciers | clients, payeurs | rapprochement et suivi d’encaissement | contrat / obligation légale | financière | facturation, comptabilité, audit |
| Journal et archives | `fiscal_events`, clôtures, archives, exports | utilisateurs et clients via métadonnées métier | intégrité, audit, obligations fiscales | obligation légale / intérêt légitime | élevée | propriétaire, administrateur, comptable, auditeur |
| Communications | relances, envois, journaux d’activité | clients, prospects, utilisateurs | suivi des envois et relances | contrat / intérêt légitime / consentement selon canal | courante | rôles métier concernés |
| Demandes de droits | `data_subject_requests`, éléments | demandeurs | répondre aux droits RGPD et conserver la preuve | obligation légale | élevée | propriétaire, administrateur ou permission explicite |
| Fichiers et logos | Supabase Storage `company-assets`, `company-files` | entreprise et contacts selon fichier | personnalisation et pièces jointes | contrat / obligation légale selon fichier | variable | RLS par entreprise et catégorie |
| Données techniques | journaux applicatifs, transmissions, webhooks | utilisateurs, systèmes tiers | sécurité, diagnostic, traçabilité | intérêt légitime | élevée | exploitation autorisée ; secrets exclus des journaux |

## Flux et isolation

- Le navigateur utilise le jeton utilisateur Supabase, jamais une clé `service_role`.
- Les tables métier sont rattachées à `company_id`; les politiques RLS et les RPC contrôlent l’entreprise active.
- Les opérations fiscales sensibles passent par des RPC et sont journalisées. Les rôles `read_only` et `auditor` n’obtiennent aucun droit d’écriture implicite.
- Les connecteurs externes de production restent désactivés tant qu’un prestataire, ses contrats et ses secrets serveur ne sont pas configurés.
- Les exports de preuve doivent exclure jetons, clés, IBAN complets et données non nécessaires.

## Points restant à instruire

1. Identifier formellement responsable de traitement, éventuels responsables conjoints et DPO.
2. Valider les bases légales par finalité, notamment prospection et relances.
3. Réaliser une AIPD si l’usage réel ou les catégories traitées le justifient.
4. Recenser les transferts hors EEE et annexes de sous-traitance réelles.
5. Configurer et exécuter les politiques de purge seulement après validation juridique et tests de restauration.

