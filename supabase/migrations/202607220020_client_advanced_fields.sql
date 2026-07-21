begin;

-- Champs additionnels pour le panneau "Options avancées" de la création
-- client (devis/facture). Migration strictement additive.
alter table public.clients
  add column if not exists date_of_birth date,
  add column if not exists secondary_phone_e164 text,
  add column if not exists secondary_email text,
  add column if not exists internal_notes text,
  add column if not exists tags text[] not null default '{}'::text[];

grant select(date_of_birth,secondary_phone_e164,secondary_email,internal_notes,tags) on public.clients to authenticated;

commit;
