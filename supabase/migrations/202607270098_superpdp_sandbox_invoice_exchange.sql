begin;

-- PILOZ reste une application de production. Seuls les échanges SUPER PDP
-- décrits ici sont verrouillés sur l'environnement sandbox.
create table if not exists public.superpdp_invoice_exchanges(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  document_id uuid references public.documents(id) on delete restrict,
  electronic_invoice_record_id uuid references public.electronic_invoice_records(id) on delete restrict,
  connector_id uuid references public.platform_connectors(id) on delete restrict,
  transmission_id uuid references public.platform_transmissions(id) on delete restrict,
  provider_invoice_id text,
  external_id text not null,
  direction text not null check(direction in('outgoing','incoming')),
  environment text not null default 'sandbox' check(environment='sandbox'),
  status text not null default 'queued',
  xml_format text check(xml_format is null or xml_format in('cii','ubl')),
  original_storage_path text,
  pdf_storage_path text,
  xml_storage_path text,
  original_sha256 text,
  pdf_sha256 text,
  xml_sha256 text,
  canonical_payload jsonb not null default '{}'::jsonb,
  provider_payload jsonb not null default '{}'::jsonb,
  last_synced_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,direction,external_id)
);

create unique index if not exists superpdp_invoice_exchanges_provider_uidx
  on public.superpdp_invoice_exchanges(company_id,direction,provider_invoice_id)
  where provider_invoice_id is not null;
create index if not exists superpdp_invoice_exchanges_document_idx
  on public.superpdp_invoice_exchanges(company_id,document_id,created_at desc);

create table if not exists public.superpdp_invoice_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  exchange_id uuid not null references public.superpdp_invoice_exchanges(id) on delete restrict,
  provider_event_id text,
  event_type text not null,
  status text,
  source text not null default 'SUPERPDP',
  payload_hash text not null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  recorded_at timestamptz not null default now(),
  unique(exchange_id,provider_event_id)
);
create index if not exists superpdp_invoice_events_exchange_idx
  on public.superpdp_invoice_events(company_id,exchange_id,occurred_at desc);

alter table public.superpdp_invoice_exchanges enable row level security;
alter table public.superpdp_invoice_events enable row level security;
drop policy if exists superpdp_invoice_exchanges_select on public.superpdp_invoice_exchanges;
create policy superpdp_invoice_exchanges_select on public.superpdp_invoice_exchanges
  for select to authenticated using(public.is_company_member(company_id));
drop policy if exists superpdp_invoice_events_select on public.superpdp_invoice_events;
create policy superpdp_invoice_events_select on public.superpdp_invoice_events
  for select to authenticated using(public.is_company_member(company_id));
revoke all on public.superpdp_invoice_exchanges,public.superpdp_invoice_events from anon,authenticated;
grant select on public.superpdp_invoice_exchanges,public.superpdp_invoice_events to authenticated;

drop trigger if exists superpdp_invoice_events_immutable on public.superpdp_invoice_events;
create trigger superpdp_invoice_events_immutable before update or delete on public.superpdp_invoice_events
for each row execute function public.protect_immutable_fiscal_row();

-- Les artefacts sont privés et restent sous le préfixe UUID de l'entreprise.
update storage.buckets set
  public=false,
  file_size_limit=10485760,
  allowed_mime_types=array[
    'application/pdf','application/xml','text/xml','application/json','application/zip','application/octet-stream',
    'text/plain','text/csv','image/png','image/jpeg','image/webp','image/svg+xml'
  ]
where id='company-files';

commit;
