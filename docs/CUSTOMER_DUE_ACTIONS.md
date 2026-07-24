# Actions des échéances clients

Le module `Ventes > Échéances clients` propose deux actions par facture finalisée :

- renvoi du PDF final par e-mail, avec destinataires multiples, copie, historique et solutions manuelles honnêtes si aucun fournisseur n’est configuré ;
- saisie d’un règlement affectable à plusieurs factures finalisées du même client et de la même devise.

Dans la popup de règlement, trois factures sont affichées au maximum avant l’action `Voir plus`. La recherche couvre le numéro, le client, l’e-mail, l’objet, les dates et le montant, tout en conservant la facture d’origine visible.

Dans le filtre `Payées`, le crayon en fin de ligne permet de corriger un règlement. Le paiement original n’est jamais supprimé : PILOZ crée une ou plusieurs écritures inverses, actualise les soldes puis rouvre la saisie afin de permettre un nouvel enregistrement correct.

## Données et sécurité

La migration `202607230052_customer_due_actions.sql` crée les reçus `payment_receipts`, leurs affectations `payment_allocations` et l’historique `document_email_deliveries`. Ces tables sont append-only, protégées par RLS et rattachées à `company_id`.

Le RPC `record_multi_invoice_payment` verrouille et recharge les factures, contrôle l’entreprise, le client, la devise, les droits, la période fiscale et l’idempotence avant de créer toutes les écritures dans une transaction. Le RPC `reverse_payment_receipt` conserve l’original et ajoute une écriture inverse à chacune de ses affectations.

## Envoi automatique

L’Edge Function `send-document-email` télécharge uniquement le PDF final privé dont le chemin appartient au document et à l’entreprise. Elle utilise Resend lorsque les secrets `RESEND_API_KEY` et `EMAIL_FROM` sont configurés. Sans `RESEND_API_KEY`, elle renvoie une indisponibilité explicite et l’interface conserve le message tout en proposant le téléchargement, la copie et l’application de messagerie.
