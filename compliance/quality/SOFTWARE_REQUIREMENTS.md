# Exigences logicielles

Les identifiants ci-dessous sont stables et reliés à la matrice de traçabilité.

- `FIS-001` : une facture finalisée reçoit un numéro serveur unique et ne peut être modifiée ou supprimée.
- `FIS-002` : les montants sont recalculés côté serveur selon une version documentée.
- `FIS-003` : chaque finalisation produit un snapshot et une preuve de version.
- `FIS-004` : une correction de facture passe par un avoir ou un nouveau document lié.
- `PAY-001` : un encaissement est append-only ; une erreur produit une écriture inverse motivée.
- `JRN-001` : les événements fiscaux sont ordonnés, hashés, chaînés et non modifiables.
- `CLO-001` : les clôtures sont figées, numérotées et chaînées.
- `ARC-001` : une archive contient manifeste, données, PDF et empreintes, et se vérifie hors application.
- `EIN-001` : le modèle canonique est indépendant de l'interface et relié au snapshot.
- `EIN-002` : aucun UBL/CII/Factur-X n'est généré sans profil officiel vérifié.
- `PDP-001` : aucune transmission de production n'est possible sans connecteur réel validé.
- `PDP-002` : les transmissions sont idempotentes et chaque état est journalisé.
- `ERP-001` : la préclassification expose règle, justification, manques et validation externe requise.
- `TEN-001` : toute donnée métier est isolée par `company_id` et RLS.
- `SEC-001` : aucune clé privée, service role ou secret n'est livré au navigateur ou à Git.
- `IAM-001` : les opérations sensibles utilisent le moindre privilège et une RPC serveur contrôlée.
- `OBS-001` : une anomalie critique est visible sans journaliser de secret ou donnée inutile.
- `BCK-001` : base, Storage, migrations et clés publiques sont sauvegardés et restaurés lors d'un exercice.
- `PRV-001` : les droits RGPD tiennent compte des obligations de conservation fiscale.
- `VER-001` : toute release enregistre version, commit, schéma et composants fiscaux.
- `QLT-001` : aucune release ne passe si tests, migration, CNAME ou scan de secrets échouent.

Les exigences juridiques et AFNOR sont provisoires tant que les textes complets et validations externes ne sont pas disponibles.
