#!/usr/bin/env node

const fs = require('node:fs');

const migrationPath = 'supabase/migrations/202608030002_restore_quote_draft_saving.sql';
const migration = fs.readFileSync(migrationPath, 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(
  migration.includes("nullif(target_document->>'client_id','')::uuid,'draft',"),
  'Un nouveau devis ou une nouvelle facture doit être créé au statut draft avant l’insertion de ses lignes.',
);
assert(
  migration.includes("if document_row.document_type='quote' then"),
  'Le verrouillage des lignes doit traiter les devis séparément des factures.',
);
assert(
  migration.includes("document_row.status in('cancelled','archived') or has_downstream_invoice"),
  'Un devis doit rester modifiable tant qu’il n’est ni archivé ni lié à une facture active.',
);
assert(
  migration.includes("elsif document_row.status<>'draft' or document_row.number is not null then"),
  'Les factures doivent conserver leur verrouillage strict hors brouillon.',
);
assert(
  migration.includes("grant execute on function public.save_document_draft(uuid,jsonb,jsonb) to authenticated"),
  'La fonction corrigée doit rester exécutable par les utilisateurs authentifiés.',
);

console.log(JSON.stringify({ ok: true, assertions: 5 }));
