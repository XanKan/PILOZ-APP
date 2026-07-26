begin;

-- Central company access-control engine. The historical role and permissions
-- columns are intentionally retained during the compatibility period.

create table if not exists public.permission_definitions(
  permission_key text primary key,
  canonical_key text not null,
  module_key text not null,
  category_key text not null,
  category_label text not null,
  label text not null,
  description text,
  allowed_scopes text[] not null default array['company'],
  sensitive boolean not null default false,
  editor_visible boolean not null default true,
  position integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(array_length(allowed_scopes,1)>0),
  check(allowed_scopes <@ array['own','team','company']::text[])
);

create table if not exists public.company_roles(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  role_key text not null,
  name text not null,
  description text,
  system_key text,
  is_system boolean not null default false,
  active boolean not null default true,
  source_role_id uuid references public.company_roles(id) on delete set null,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((is_system and system_key in('administrator','user','commercial','accountant')) or (not is_system and system_key is null))
);
create unique index if not exists company_roles_key_unique on public.company_roles(company_id,role_key);
create unique index if not exists company_roles_system_unique on public.company_roles(company_id,system_key) where is_system;
create unique index if not exists company_roles_name_unique on public.company_roles(company_id,lower(name)) where active;

create table if not exists public.company_role_permissions(
  role_id uuid not null references public.company_roles(id) on delete cascade,
  permission_key text not null references public.permission_definitions(permission_key) on delete restrict,
  scope text not null default 'company' check(scope in('own','team','company')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key(role_id,permission_key)
);

create table if not exists public.company_teams(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  description text,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now()
);
create unique index if not exists company_teams_name_unique on public.company_teams(company_id,lower(name)) where active;

create table if not exists public.company_team_members(
  company_id uuid not null references public.companies(id) on delete cascade,
  team_id uuid not null references public.company_teams(id) on delete cascade,
  user_id uuid not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key(team_id,user_id)
);
create index if not exists company_team_members_user_idx on public.company_team_members(company_id,user_id,team_id);

alter table public.company_members
  add column if not exists role_id uuid references public.company_roles(id) on delete restrict,
  add column if not exists primary_team_id uuid references public.company_teams(id) on delete set null,
  add column if not exists access_removed_at timestamptz,
  add column if not exists access_removed_by uuid;
alter table public.company_members drop constraint if exists company_members_platform_status_check;
alter table public.company_members add constraint company_members_platform_status_check
  check(platform_status in('pending','active','suspended','removed')) not valid;
create index if not exists company_members_role_idx on public.company_members(company_id,role_id,platform_status);

create table if not exists public.company_invitations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  first_name text not null,
  last_name text not null,
  intended_role_id uuid not null references public.company_roles(id) on delete restrict,
  intended_team_id uuid references public.company_teams(id) on delete set null,
  invited_user_id uuid,
  token_hash text,
  status text not null default 'pending' check(status in('pending','sent','accepted','expired','revoked','failed')),
  delivery_status text not null default 'pending' check(delivery_status in('pending','sent','not_configured','failed')),
  send_count integer not null default 0 check(send_count>=0),
  last_sent_at timestamptz,
  delivery_error text,
  expires_at timestamptz not null default now()+interval '7 days',
  accepted_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  invited_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(email=lower(trim(email)))
);
create unique index if not exists company_invitations_pending_email_unique
  on public.company_invitations(company_id,lower(email)) where status in('pending','sent');
create index if not exists company_invitations_company_status_idx on public.company_invitations(company_id,status,created_at desc);

create table if not exists public.company_access_audit(
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete restrict,
  actor_user_id uuid,
  action text not null,
  target_type text not null,
  target_id text,
  previous_state jsonb,
  new_state jsonb,
  reason text,
  request_id text,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists company_access_audit_lookup_idx on public.company_access_audit(company_id,created_at desc,id desc);
create index if not exists company_access_audit_target_idx on public.company_access_audit(company_id,target_type,target_id,created_at desc);

-- Canonical catalogue. Historical keys are aliases and stay hidden from the editor.
insert into public.permission_definitions(permission_key,canonical_key,module_key,category_key,category_label,label,description,allowed_scopes,sensitive,editor_visible,position) values
('application.read','application.read','application','user','Utilisateur','Accéder à Piloz','Ouvrir l’application pour cette entreprise.',array['own','team','company'],false,true,10),
('dashboard.read','dashboard.read','dashboard','dashboard','Tableau de bord','Consulter le tableau de bord','Voir les indicateurs autorisés.',array['own','team','company'],false,true,20),
('dashboard.manage','dashboard.manage','dashboard','dashboard','Tableau de bord','Personnaliser les tableaux de bord','Créer, réordonner et partager des dispositions.',array['own','team','company'],false,true,21),
('company.settings.manage','company.settings.manage','administration','administration','Administration','Paramétrer l’entreprise','Modifier les informations et réglages globaux.',array['company'],true,true,30),
('company.users.read','company.users.read','administration','administration','Administration','Consulter les utilisateurs','Voir les membres, rôles et invitations.',array['company'],true,true,31),
('company.users.manage','company.users.manage','administration','administration','Administration','Gérer les utilisateurs et les accès','Inviter, suspendre, réactiver et attribuer un rôle.',array['company'],true,true,32),
('company.roles.manage','company.roles.manage','administration','administration','Administration','Gérer les rôles personnalisés','Créer, modifier, dupliquer et archiver des rôles.',array['company'],true,true,33),
('company.subscription.manage','company.subscription.manage','administration','administration','Administration','Gérer l’abonnement','Consulter et modifier l’offre Piloz.',array['company'],true,true,34),
('company.templates.manage','company.templates.manage','administration','administration','Administration','Gérer les modèles de documents','Créer et modifier les modèles, CGV et pieds de page.',array['company'],true,true,35),
('clients.read','clients.read','crm','tiers','Tiers','Consulter les clients','Voir les fiches clients et contacts autorisés.',array['own','team','company'],false,true,100),
('clients.write','clients.write','crm','tiers','Tiers','Créer et modifier des clients','Créer et modifier les clients dans la portée autorisée.',array['own','team','company'],false,true,101),
('suppliers.read','suppliers.read','purchases','tiers','Tiers','Consulter les fournisseurs','Voir les fournisseurs et sous-traitants.',array['own','team','company'],false,true,102),
('suppliers.write','suppliers.write','purchases','tiers','Tiers','Gérer les fournisseurs','Créer et modifier fournisseurs et sous-traitants.',array['own','team','company'],false,true,103),
('crm.prospects.read','crm.prospects.read','crm','crm','Suivi commercial','Consulter les prospects','Voir les prospects de la portée autorisée.',array['own','team','company'],false,true,120),
('crm.prospects.write','crm.prospects.write','crm','crm','Suivi commercial','Créer et modifier des prospects','Gérer les prospects de la portée autorisée.',array['own','team','company'],false,true,121),
('crm.opportunities.read','crm.opportunities.read','crm','crm','Suivi commercial','Consulter le pipeline','Voir les opportunités autorisées.',array['own','team','company'],false,true,122),
('crm.opportunities.write','crm.opportunities.write','crm','crm','Suivi commercial','Gérer les opportunités','Créer, déplacer, gagner ou perdre une opportunité.',array['own','team','company'],false,true,123),
('crm.activities.read','crm.activities.read','crm','crm','Suivi commercial','Consulter les activités','Voir activités, rendez-vous et notes autorisés.',array['own','team','company'],false,true,124),
('crm.activities.write','crm.activities.write','crm','crm','Suivi commercial','Créer et modifier des activités','Planifier, terminer et replanifier une activité.',array['own','team','company'],false,true,125),
('crm.reminders.manage','crm.reminders.manage','crm','crm','Suivi commercial','Gérer les relances commerciales','Créer et suivre les relances autorisées.',array['own','team','company'],false,true,126),
('crm.reports.read','crm.reports.read','crm','crm','Suivi commercial','Consulter les rapports commerciaux','Voir les rapports selon la portée autorisée.',array['own','team','company'],false,true,127),
('sales.quotes.read','sales.quotes.read','sales','sales','Devis et factures','Consulter les devis','Voir et télécharger les devis autorisés.',array['own','team','company'],false,true,200),
('sales.quotes.create','sales.quotes.create','sales','sales','Devis et factures','Créer des devis','Créer un devis dans la portée autorisée.',array['own','team','company'],false,true,201),
('sales.quotes.update_draft','sales.quotes.update_draft','sales','sales','Devis et factures','Modifier les devis brouillons','Modifier un brouillon autorisé.',array['own','team','company'],false,true,202),
('sales.quotes.finalize','sales.quotes.finalize','sales','sales','Devis et factures','Finaliser les devis','Attribuer un numéro définitif et verrouiller le devis.',array['own','team','company'],true,true,203),
('sales.quotes.send','sales.quotes.send','sales','sales','Devis et factures','Envoyer et relancer les devis','Envoyer, renvoyer et relancer un devis.',array['own','team','company'],false,true,204),
('sales.quotes.convert','sales.quotes.convert','sales','sales','Devis et factures','Convertir un devis','Créer une facture brouillon depuis un devis accepté.',array['own','team','company'],false,true,205),
('sales.invoices.read','sales.invoices.read','sales','sales','Devis et factures','Consulter les factures et avoirs','Voir les factures, avoirs, PDF et échéances.',array['own','team','company'],false,true,210),
('sales.invoices.create_draft','sales.invoices.create_draft','sales','sales','Devis et factures','Créer des factures brouillons','Créer une facture sans la finaliser.',array['own','team','company'],false,true,211),
('sales.invoices.update_draft','sales.invoices.update_draft','sales','sales','Devis et factures','Modifier les factures brouillons','Modifier uniquement les brouillons autorisés.',array['own','team','company'],false,true,212),
('sales.invoices.finalize','sales.invoices.finalize','sales','sales','Devis et factures','Finaliser les factures','Attribuer un numéro fiscal définitif.',array['own','team','company'],true,true,213),
('sales.invoices.send','sales.invoices.send','sales','sales','Devis et factures','Envoyer les factures','Envoyer ou renvoyer une facture autorisée.',array['own','team','company'],false,true,214),
('sales.credit_notes.create','sales.credit_notes.create','sales','sales','Devis et factures','Créer des avoirs','Corriger une facture finalisée par un avoir.',array['company'],true,true,215),
('sales.receivables.read','sales.receivables.read','sales','sales','Devis et factures','Consulter les échéances','Voir les montants restant à payer et les retards.',array['own','team','company'],false,true,216),
('sales.receivables.remind','sales.receivables.remind','sales','sales','Devis et factures','Relancer les factures','Créer et envoyer une relance client.',array['own','team','company'],false,true,217),
('payments.read','payments.read','accounting','accounting','Gestion et comptabilité','Consulter les règlements','Voir règlements et affectations.',array['own','team','company'],true,true,300),
('payments.create','payments.create','accounting','accounting','Gestion et comptabilité','Saisir des règlements','Créer et affecter un règlement.',array['company'],true,true,301),
('payments.cancel','payments.cancel','accounting','accounting','Gestion et comptabilité','Annuler ou corriger des règlements','Créer une contre-écriture traçable.',array['company'],true,true,302),
('payments.bank_details.read','payments.bank_details.read','accounting','accounting','Gestion et comptabilité','Consulter les références bancaires','Voir les comptes et références bancaires des règlements.',array['company'],true,true,303),
('payments.proofs.manage','payments.proofs.manage','accounting','accounting','Gestion et comptabilité','Gérer les justificatifs de règlement','Ajouter et télécharger les justificatifs de règlement.',array['company'],true,true,304),
('accounting.entries.read','accounting.entries.read','accounting','accounting','Gestion et comptabilité','Consulter les écritures','Voir les écritures et journaux comptables.',array['company'],true,true,310),
('accounting.exports.manage','accounting.exports.manage','accounting','accounting','Gestion et comptabilité','Gérer les exports comptables','Prévisualiser, valider et télécharger les exports.',array['company'],true,true,311),
('accounting.settings.manage','accounting.settings.manage','accounting','accounting','Gestion et comptabilité','Gérer le paramétrage comptable','Gérer comptes, journaux, TVA et exercices.',array['company'],true,true,312),
('accounting.vat.manage','accounting.vat.manage','accounting','accounting','Gestion et comptabilité','Préparer la TVA','Consulter et préparer la TVA sur encaissements.',array['company'],true,true,313),
('purchases.orders.read','purchases.orders.read','purchases','purchases','Achats','Consulter les commandes fournisseurs','Voir les commandes et réceptions.',array['own','team','company'],false,true,400),
('purchases.orders.write','purchases.orders.write','purchases','purchases','Achats','Gérer les commandes fournisseurs','Créer, modifier et confirmer les commandes.',array['own','team','company'],false,true,401),
('purchases.invoices.read','purchases.invoices.read','purchases','purchases','Achats','Consulter les factures d’achat','Voir les factures fournisseurs.',array['own','team','company'],true,true,402),
('purchases.invoices.write','purchases.invoices.write','purchases','purchases','Achats','Gérer les factures d’achat','Créer et modifier les factures fournisseurs.',array['company'],true,true,403),
('catalog.read','catalog.read','catalog','catalog','Catalogue','Consulter les articles et services','Voir le catalogue et les prix de vente.',array['company'],false,true,500),
('catalog.write','catalog.write','catalog','catalog','Catalogue','Gérer les articles et services','Créer et modifier les éléments du catalogue.',array['company'],false,true,501),
('catalog.purchase_price.read','catalog.purchase_price.read','catalog','catalog','Catalogue','Voir les prix d’achat','Afficher prix d’achat et coûts de revient.',array['company'],true,true,502),
('catalog.margin.read','catalog.margin.read','catalog','catalog','Catalogue','Voir les marges','Afficher les marges commerciales.',array['company'],true,true,503),
('stock.read','stock.read','stock','stock','Stock','Consulter le stock','Voir niveaux, mouvements et réceptions.',array['company'],false,true,520),
('stock.write','stock.write','stock','stock','Stock','Gérer le stock','Ajuster stocks, inventaires et emplacements.',array['company'],true,true,521),
('extensions.personal.manage','extensions.personal.manage','extensions','user','Utilisateur','Gérer ses extensions personnelles','Connecter sa messagerie et son agenda personnels.',array['own'],false,true,600),
('extensions.company.manage','extensions.company.manage','extensions','administration','Administration','Gérer les extensions d’entreprise','Configurer les connexions partagées et globales.',array['company'],true,true,601),
('user.preferences.manage','user.preferences.manage','user','user','Utilisateur','Modifier ses préférences','Gérer ses préférences et notifications.',array['own'],false,true,610),
('user.agenda.read','user.agenda.read','user','user','Utilisateur','Accéder à son agenda','Consulter son agenda personnel.',array['own'],false,true,611),
('reports.company.read','reports.company.read','reports','dashboard','Tableau de bord','Consulter les rapports globaux','Voir les statistiques de toute l’entreprise.',array['company'],true,true,620),
('compliance.read','compliance.read','compliance','administration','Administration','Consulter la conformité','Voir les journaux fiscaux, RGPD et contrôles internes.',array['company'],true,true,630),
('support.read','support.read','support','support','Assistance et support','Accéder au support Piloz','Ouvrir l’aide et le support technique.',array['own','company'],false,true,700),

-- Historical aliases used by existing policies, triggers and JavaScript.
('application_read','application.read','application','legacy','Historique','Accès application',null,array['own','team','company'],false,false,900),
('manage_customer','clients.write','crm','legacy','Historique','Gestion clients',null,array['own','team','company'],false,false,901),
('manage_opportunity','crm.opportunities.write','crm','legacy','Historique','Gestion opportunités',null,array['own','team','company'],false,false,902),
('manage_reminder','crm.reminders.manage','crm','legacy','Historique','Gestion relances',null,array['own','team','company'],false,false,903),
('sales_document_write','sales.quotes.update_draft','sales','legacy','Historique','Écriture documents commerciaux',null,array['own','team','company'],false,false,904),
('finalize_quote','sales.quotes.finalize','sales','legacy','Historique','Finalisation devis',null,array['own','team','company'],true,false,905),
('finalize_invoice','sales.invoices.finalize','sales','legacy','Historique','Finalisation facture',null,array['own','team','company'],true,false,906),
('create_credit_note','sales.credit_notes.create','sales','legacy','Historique','Création avoir',null,array['company'],true,false,907),
('view_due_dates','sales.receivables.read','sales','legacy','Historique','Lecture échéances',null,array['own','team','company'],false,false,908),
('resend_invoice','sales.invoices.send','sales','legacy','Historique','Renvoi facture',null,array['own','team','company'],false,false,909),
('record_payment','payments.create','accounting','legacy','Historique','Saisie règlement',null,array['company'],true,false,910),
('record_multi_invoice_payment','payments.create','accounting','legacy','Historique','Saisie multi-règlement',null,array['company'],true,false,911),
('correct_payment','payments.cancel','accounting','legacy','Historique','Correction règlement',null,array['company'],true,false,912),
('accounting_payment_reverse','payments.cancel','accounting','legacy','Historique','Contrepassation règlement',null,array['company'],true,false,913),
('accounting_payments_read','payments.read','accounting','legacy','Historique','Lecture règlements',null,array['company'],true,false,914),
('accounting_entries_read','accounting.entries.read','accounting','legacy','Historique','Lecture écritures',null,array['company'],true,false,915),
('accounting_export_preview','accounting.exports.manage','accounting','legacy','Historique','Prévisualisation export',null,array['company'],true,false,916),
('accounting_export_validate','accounting.exports.manage','accounting','legacy','Historique','Validation export',null,array['company'],true,false,917),
('accounting_export_cancel','accounting.exports.manage','accounting','legacy','Historique','Annulation export',null,array['company'],true,false,918),
('accounting_attachments_download','accounting.exports.manage','accounting','legacy','Historique','Téléchargement pièces',null,array['company'],true,false,919),
('accounting_settings_manage','accounting.settings.manage','accounting','legacy','Historique','Paramétrage comptable',null,array['company'],true,false,920),
('accounting_vat_cash','accounting.vat.manage','accounting','legacy','Historique','TVA encaissements',null,array['company'],true,false,921),
('accounting_fiscal_year_manage','accounting.settings.manage','accounting','legacy','Historique','Exercices fiscaux',null,array['company'],true,false,922),
('view_purchase_prices','catalog.purchase_price.read','catalog','legacy','Historique','Prix achat',null,array['company'],true,false,923),
('view_margins','catalog.margin.read','catalog','legacy','Historique','Marges',null,array['company'],true,false,924),
('adjust_stock','stock.write','stock','legacy','Historique','Ajustement stock',null,array['company'],true,false,925),
('extensions_read','extensions.personal.manage','extensions','legacy','Historique','Lecture extensions',null,array['own'],false,false,926),
('extensions_connect_own','extensions.personal.manage','extensions','legacy','Historique','Connexion personnelle',null,array['own'],false,false,927),
('extensions_manage_global','extensions.company.manage','extensions','legacy','Historique','Connexion globale',null,array['company'],true,false,928),
('manage_document_templates','company.templates.manage','administration','legacy','Historique','Modèles documents',null,array['company'],true,false,929),
('manage_purchase_orders','purchases.orders.write','purchases','legacy','Historique','Commandes fournisseurs',null,array['company'],false,false,930),
('fiscal_read','compliance.read','compliance','legacy','Historique','Lecture fiscale',null,array['company'],true,false,931),
('compliance_view','compliance.read','compliance','legacy','Historique','Conformité',null,array['company'],true,false,932),
('personal_data_audit','compliance.read','compliance','legacy','Historique','Audit données personnelles',null,array['company'],true,false,933),
('personal_data_manage','compliance.read','compliance','legacy','Historique','Gestion données personnelles',null,array['company'],true,false,934),
('view_bank_accounts','payments.bank_details.read','accounting','legacy','Historique','Comptes bancaires',null,array['company'],true,false,935),
('view_bank_references','payments.bank_details.read','accounting','legacy','Historique','Références bancaires',null,array['company'],true,false,936),
('view_payment_methods','payments.read','accounting','legacy','Historique','Modes de paiement',null,array['company'],true,false,937),
('attach_payment_proof','payments.proofs.manage','accounting','legacy','Historique','Justificatif règlement',null,array['company'],true,false,938),
('create_closure','compliance.read','compliance','legacy','Historique','Clôture fiscale',null,array['company'],true,false,939),
('create_archive','compliance.read','compliance','legacy','Historique','Archive fiscale',null,array['company'],true,false,940),
('electronic_invoice_manage','accounting.settings.manage','accounting','legacy','Historique','Facturation électronique',null,array['company'],true,false,941)
on conflict(permission_key) do update set canonical_key=excluded.canonical_key,module_key=excluded.module_key,
  category_key=excluded.category_key,category_label=excluded.category_label,label=excluded.label,
  description=excluded.description,allowed_scopes=excluded.allowed_scopes,sensitive=excluded.sensitive,
  editor_visible=excluded.editor_visible,position=excluded.position,active=true,updated_at=now();

create or replace function public.seed_company_access_roles(target_company_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare admin_id uuid; user_id_value uuid; commercial_id uuid; accountant_id uuid;
begin
  perform set_config('piloz.system_role_seed','1',true);
  insert into public.company_roles(company_id,role_key,name,description,system_key,is_system)
  values
    (target_company_id,'administrator','Administrateur','Accès complet à l’entreprise, aux utilisateurs, aux paramètres et à l’ensemble des fonctionnalités Piloz.','administrator',true),
    (target_company_id,'user','Utilisateur','Accès aux fonctions courantes de gestion commerciale, sans administration avancée de l’entreprise.','user',true),
    (target_company_id,'commercial','Commercial','Accès au CRM, aux clients, aux devis et au suivi des factures de son portefeuille, sans droits comptables.','commercial',true),
    (target_company_id,'accountant','Expert-comptable','Accès en lecture aux factures et aux fonctionnalités comptables de l’entreprise.','accountant',true)
  on conflict(company_id,role_key) do update set name=excluded.name,description=excluded.description,
    system_key=excluded.system_key,is_system=true,active=true,updated_at=now();

  select id into admin_id from public.company_roles where company_id=target_company_id and system_key='administrator';
  select id into user_id_value from public.company_roles where company_id=target_company_id and system_key='user';
  select id into commercial_id from public.company_roles where company_id=target_company_id and system_key='commercial';
  select id into accountant_id from public.company_roles where company_id=target_company_id and system_key='accountant';

  insert into public.company_role_permissions(role_id,permission_key,scope)
  select admin_id,definition.permission_key,'company' from public.permission_definitions definition
  where definition.permission_key=definition.canonical_key and definition.active
  on conflict(role_id,permission_key) do update set scope='company',updated_at=now();

  insert into public.company_role_permissions(role_id,permission_key,scope)
  select user_id_value,value.permission_key,value.scope from (values
    ('application.read','company'),('dashboard.read','own'),('clients.read','company'),('clients.write','own'),
    ('crm.prospects.read','own'),('crm.prospects.write','own'),('crm.opportunities.read','own'),('crm.opportunities.write','own'),
    ('crm.activities.read','own'),('crm.activities.write','own'),('crm.reminders.manage','own'),
    ('sales.quotes.read','own'),('sales.quotes.create','own'),('sales.quotes.update_draft','own'),
    ('sales.quotes.send','own'),('sales.invoices.read','own'),('sales.receivables.read','own'),('payments.read','own'),('catalog.read','company'),
    ('extensions.personal.manage','own'),('user.preferences.manage','own'),('user.agenda.read','own'),('support.read','own')
  ) value(permission_key,scope)
  on conflict(role_id,permission_key) do update set scope=excluded.scope,updated_at=now();

  insert into public.company_role_permissions(role_id,permission_key,scope)
  select commercial_id,value.permission_key,value.scope from (values
    ('application.read','company'),('dashboard.read','own'),('clients.read','team'),('clients.write','team'),
    ('crm.prospects.read','team'),('crm.prospects.write','team'),('crm.opportunities.read','team'),('crm.opportunities.write','team'),
    ('crm.activities.read','team'),('crm.activities.write','team'),('crm.reminders.manage','team'),('crm.reports.read','own'),
    ('sales.quotes.read','team'),('sales.quotes.create','own'),('sales.quotes.update_draft','own'),
    ('sales.quotes.finalize','own'),('sales.quotes.send','team'),('sales.quotes.convert','own'),
    ('sales.invoices.read','team'),('sales.invoices.create_draft','own'),('sales.invoices.update_draft','own'),
    ('sales.invoices.send','team'),('sales.receivables.read','team'),('sales.receivables.remind','team'),
    ('payments.read','team'),('catalog.read','company'),('extensions.personal.manage','own'),
    ('user.preferences.manage','own'),('user.agenda.read','own'),('support.read','own')
  ) value(permission_key,scope)
  on conflict(role_id,permission_key) do update set scope=excluded.scope,updated_at=now();

  insert into public.company_role_permissions(role_id,permission_key,scope)
  select accountant_id,value.permission_key,'company' from unnest(array[
    'application.read','clients.read','sales.invoices.read','sales.receivables.read','payments.read','payments.bank_details.read','payments.proofs.manage','accounting.entries.read',
    'accounting.exports.manage','accounting.settings.manage','accounting.vat.manage','compliance.read',
    'user.preferences.manage','support.read'
  ]::text[]) value(permission_key)
  on conflict(role_id,permission_key) do update set scope='company',updated_at=now();
  perform set_config('piloz.system_role_seed','0',true);
end
$$;
revoke all on function public.seed_company_access_roles(uuid) from public,anon,authenticated;

select public.seed_company_access_roles(company.id) from public.companies company;

-- Preserve non-standard historical Commercial rights in a custom role.
do $migration$
declare company_row record; historical_role_id uuid; commercial_role_id uuid; permission_row record;
begin
  for company_row in
    select distinct member.company_id from public.company_members member where member.role='sales' and exists(
      select 1 from jsonb_each(coalesce(member.permissions,'{}'::jsonb)) item
      where (jsonb_typeof(item.value)='boolean' and item.value='true'::jsonb)
         or item.key not in('view_purchase_prices','view_margins','adjust_stock')
    )
  loop
    select id into commercial_role_id from public.company_roles where company_id=company_row.company_id and system_key='commercial';
    insert into public.company_roles(company_id,role_key,name,description,is_system,source_role_id)
    values(company_row.company_id,'commercial-historique','Commercial historique','Rôle conservant les exceptions de permissions de l’ancien rôle Commercial.',false,commercial_role_id)
    on conflict(company_id,role_key) do update set active=true,updated_at=now() returning id into historical_role_id;
    insert into public.company_role_permissions(role_id,permission_key,scope)
    select historical_role_id,permission_key,scope from public.company_role_permissions where role_id=commercial_role_id
    on conflict(role_id,permission_key) do nothing;
    for permission_row in
      select distinct definition.canonical_key, bool_or(lower(item.value#>>'{}')='true') enabled
      from public.company_members member cross join lateral jsonb_each(coalesce(member.permissions,'{}'::jsonb)) item
      join public.permission_definitions definition on definition.permission_key=item.key
      where member.company_id=company_row.company_id and member.role='sales' group by definition.canonical_key
    loop
      if permission_row.enabled then
        insert into public.company_role_permissions(role_id,permission_key,scope)
        values(historical_role_id,permission_row.canonical_key,'company') on conflict(role_id,permission_key) do update set scope='company';
      else
        delete from public.company_role_permissions where role_id=historical_role_id and permission_key=permission_row.canonical_key;
      end if;
    end loop;
  end loop;
end
$migration$;

-- Every legacy member receives exactly one central role.
update public.company_members member set role_id=coalesce(
  case when member.role='sales' and exists(
    select 1 from jsonb_each(coalesce(member.permissions,'{}'::jsonb)) item
    where (jsonb_typeof(item.value)='boolean' and item.value='true'::jsonb)
       or item.key not in('view_purchase_prices','view_margins','adjust_stock')
  ) then (select role.id from public.company_roles role where role.company_id=member.company_id and role.role_key='commercial-historique') end,
  (select role.id from public.company_roles role where role.company_id=member.company_id and role.system_key=case
    when member.role in('owner','admin') then 'administrator'
    when member.role='sales' then 'commercial'
    when member.role in('billing','accounting','auditor') then 'accountant'
    else 'user' end)
) where member.role_id is null;

update public.company_members set permissions=coalesce(permissions,'{}'::jsonb)||jsonb_build_object(
  'manage_customer',false,'clients.write',false,'manage_opportunity',false,'crm.opportunities.write',false,
  'sales_document_write',false,'sales.quotes.create',false,'sales.quotes.update_draft',false,
  'sales.invoices.create_draft',false,'sales.invoices.update_draft',false
) where role='read_only';

create or replace function public.company_permission_scope(
  target_company_id uuid,target_permission text,target_user_id uuid default auth.uid()
) returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare member_row public.company_members%rowtype; canonical text; resolved_scope text;
begin
  select * into member_row from public.company_members member
  where member.company_id=target_company_id and member.user_id=target_user_id and member.platform_status='active';
  if member_row.user_id is null then return 'none'; end if;
  select definition.canonical_key into canonical from public.permission_definitions definition
  where definition.permission_key=target_permission and definition.active;
  canonical:=coalesce(canonical,target_permission);
  if member_row.permissions ? target_permission then
    if lower(member_row.permissions->>target_permission)='false' then return 'none'; end if;
    if lower(member_row.permissions->>target_permission)='true' then return 'company'; end if;
  end if;
  if member_row.permissions ? canonical then
    if lower(member_row.permissions->>canonical)='false' then return 'none'; end if;
    if lower(member_row.permissions->>canonical)='true' then return 'company'; end if;
  end if;
  select permission.scope into resolved_scope from public.company_role_permissions permission
  join public.company_roles role on role.id=permission.role_id and role.company_id=target_company_id and role.active
  where permission.role_id=member_row.role_id and permission.permission_key=canonical;
  if resolved_scope is not null then return resolved_scope; end if;
  -- Compatibility only for a member not yet migrated.
  if member_row.role in('owner','admin') then return 'company'; end if;
  return 'none';
end
$$;
revoke all on function public.company_permission_scope(uuid,text,uuid) from public,anon;
grant execute on function public.company_permission_scope(uuid,text,uuid) to authenticated;

create or replace function public.has_company_permission(target_company_id uuid,target_permission text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.company_permission_scope(target_company_id,target_permission,auth.uid())<>'none'
$$;
revoke all on function public.has_company_permission(uuid,text) from public,anon;
grant execute on function public.has_company_permission(uuid,text) to authenticated;

create or replace function public.has_company_permission(
  target_company_id uuid,target_permission text,required_scope text,resource_owner_id uuid,resource_team_id uuid
) returns boolean language plpgsql stable security definer set search_path=public,pg_temp as $$
declare granted_scope text; actor uuid:=auth.uid();
begin
  if required_scope not in('own','team','company') then return false; end if;
  granted_scope:=public.company_permission_scope(target_company_id,target_permission,actor);
  if granted_scope='company' then return true; end if;
  if granted_scope='own' then return resource_owner_id=actor; end if;
  if granted_scope='team' then
    return resource_owner_id=actor or exists(
      select 1 from public.company_team_members team_member
      where team_member.company_id=target_company_id and team_member.user_id=actor and team_member.team_id=resource_team_id
    ) or exists(
      select 1 from public.company_team_members mine join public.company_team_members resource
        on resource.company_id=mine.company_id and resource.team_id=mine.team_id
      where mine.company_id=target_company_id and mine.user_id=actor and resource.user_id=resource_owner_id
    );
  end if;
  return false;
end
$$;
revoke all on function public.has_company_permission(uuid,text,text,uuid,uuid) from public,anon;
grant execute on function public.has_company_permission(uuid,text,text,uuid,uuid) to authenticated;

create or replace function public.resolve_company_permissions(target_user_id uuid,target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare member_row public.company_members%rowtype; role_row public.company_roles%rowtype; permissions_value jsonb;
begin
  if auth.uid() is not null and auth.uid()<>target_user_id
    and not public.has_company_permission(target_company_id,'company.users.read') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  select * into member_row from public.company_members where company_id=target_company_id and user_id=target_user_id;
  if member_row.user_id is null then return jsonb_build_object('company_id',target_company_id,'user_id',target_user_id,'status','not_member','permissions','{}'::jsonb); end if;
  select * into role_row from public.company_roles where id=member_row.role_id and company_id=target_company_id;
  select coalesce(jsonb_object_agg(definition.permission_key,resolved.scope),'{}'::jsonb) into permissions_value
  from public.permission_definitions definition
  cross join lateral (
    select public.company_permission_scope(target_company_id,definition.permission_key,target_user_id) scope
  ) resolved
  where definition.permission_key=definition.canonical_key and definition.active and resolved.scope<>'none';
  return jsonb_build_object(
    'company_id',target_company_id,'user_id',target_user_id,'member_status',member_row.platform_status,
    'role',jsonb_build_object('id',role_row.id,'key',role_row.role_key,'name',role_row.name,'system_key',role_row.system_key,'is_system',role_row.is_system),
    'permissions',permissions_value,'legacy_overrides',coalesce(member_row.permissions,'{}'::jsonb),
    'primary_team_id',member_row.primary_team_id,'version','202607260081',
    'restrictions',case when role_row.system_key='commercial' then jsonb_build_object('invoice_finalization',false,'payments_write',false,'purchase_prices',false,'margins',false) else '{}'::jsonb end
  );
end
$$;
revoke all on function public.resolve_company_permissions(uuid,uuid) from public,anon;
grant execute on function public.resolve_company_permissions(uuid,uuid) to authenticated;

-- Legacy helper now resolves against the same central role source.
create or replace function public.has_company_role(target_company_id uuid,allowed_roles text[])
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(
    select 1 from public.company_members member left join public.company_roles role on role.id=member.role_id
    where member.company_id=target_company_id and member.user_id=auth.uid() and member.platform_status='active'
      and (member.role=any(allowed_roles)
        or (role.system_key='administrator' and allowed_roles && array['owner','admin'])
        or (role.system_key='commercial' and 'sales'=any(allowed_roles))
        or (role.system_key='accountant' and allowed_roles && array['accounting','billing','auditor'])
        or (role.system_key='user' and allowed_roles && array['member','read_only']))
  )
$$;
create or replace function public.is_company_member(target_company_id uuid)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from public.company_members member join public.companies company on company.id=member.company_id
    where member.company_id=target_company_id and member.user_id=auth.uid() and member.platform_status='active'
      and company.platform_status='active')
$$;
create or replace function public.current_user_company_ids() returns table(company_id uuid)
language sql stable security definer set search_path=public,pg_temp as $$
  select member.company_id from public.company_members member join public.companies company on company.id=member.company_id
  where member.user_id=auth.uid() and member.platform_status='active' and company.platform_status='active'
$$;

create or replace function public.protect_system_company_role()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if old.is_system and auth.uid() is not null and coalesce(current_setting('piloz.system_role_seed',true),'0')<>'1' then
    raise exception 'Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.' using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists company_roles_protect_system on public.company_roles;
create trigger company_roles_protect_system before update or delete on public.company_roles
for each row execute function public.protect_system_company_role();

create or replace function public.protect_system_role_permission()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare target_role_id uuid:=coalesce(new.role_id,old.role_id);
begin
  if auth.uid() is not null and coalesce(current_setting('piloz.system_role_seed',true),'0')<>'1'
    and exists(select 1 from public.company_roles where id=target_role_id and is_system) then
    raise exception 'Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.' using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists company_role_permissions_protect_system on public.company_role_permissions;
create trigger company_role_permissions_protect_system before insert or update or delete on public.company_role_permissions
for each row execute function public.protect_system_role_permission();

create or replace function public.protect_last_company_administrator()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare company_value uuid:=coalesce(new.company_id,old.company_id); removes_admin boolean:=false; active_admins integer;
begin
  if tg_op='DELETE' then
    removes_admin:=old.platform_status='active' and exists(select 1 from public.company_roles where id=old.role_id and system_key='administrator');
  else
    removes_admin:=old.platform_status='active' and exists(select 1 from public.company_roles where id=old.role_id and system_key='administrator')
      and (new.platform_status<>'active' or new.role_id is distinct from old.role_id);
  end if;
  if removes_admin then
    select count(*) into active_admins from public.company_members member join public.company_roles role on role.id=member.role_id
    where member.company_id=company_value and member.user_id<>old.user_id and member.platform_status='active' and role.system_key='administrator';
    if active_admins=0 then raise exception 'L’entreprise doit toujours conserver au moins un administrateur actif.' using errcode='42501'; end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;

create or replace function public.assign_company_member_central_role()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.role_id is null then
    select role.id into new.role_id from public.company_roles role
    where role.company_id=new.company_id and role.system_key=case
      when new.role in('owner','admin') then 'administrator'
      when new.role='sales' then 'commercial'
      when new.role in('billing','accounting','auditor') then 'accountant'
      else 'user' end;
  end if;
  if new.role='read_only' then
    new.permissions:=coalesce(new.permissions,'{}'::jsonb)||jsonb_build_object(
      'manage_customer',false,'clients.write',false,'manage_opportunity',false,'crm.opportunities.write',false,
      'sales_document_write',false,'sales.quotes.create',false,'sales.quotes.update_draft',false,
      'sales.invoices.create_draft',false,'sales.invoices.update_draft',false
    );
  end if;
  return new;
end
$$;
drop trigger if exists company_members_assign_central_role on public.company_members;
create trigger company_members_assign_central_role before insert or update of role,role_id on public.company_members
for each row execute function public.assign_company_member_central_role();

drop trigger if exists company_members_protect_last_administrator on public.company_members;
create trigger company_members_protect_last_administrator before update of role_id,platform_status or delete on public.company_members
for each row execute function public.protect_last_company_administrator();

create or replace function public.protect_company_access_audit()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'company_access_audit_is_append_only' using errcode='42501'; end
$$;
drop trigger if exists company_access_audit_immutable on public.company_access_audit;
create trigger company_access_audit_immutable before update or delete on public.company_access_audit
for each row execute function public.protect_company_access_audit();

create or replace function public.append_company_access_audit(
  target_company_id uuid,target_action text,target_type text,target_id text,
  target_previous jsonb default null,target_new jsonb default null,target_reason text default null,
  target_actor uuid default auth.uid(),target_request_id text default null
) returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare result_id bigint;
begin
  insert into public.company_access_audit(company_id,actor_user_id,action,target_type,target_id,previous_state,new_state,reason,request_id)
  values(target_company_id,target_actor,target_action,target_type,target_id,target_previous,target_new,nullif(trim(target_reason),''),target_request_id)
  returning id into result_id;
  return result_id;
end
$$;
revoke all on function public.append_company_access_audit(uuid,text,text,text,jsonb,jsonb,text,uuid,text) from public,anon,authenticated;

create or replace function public.log_central_member_access_change()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform public.append_company_access_audit(coalesce(new.company_id,old.company_id),'member.'||lower(tg_op),'company_member',
    coalesce(new.user_id,old.user_id)::text,case when tg_op in('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in('INSERT','UPDATE') then to_jsonb(new) else null end,null,auth.uid(),null);
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists company_members_log_central_access on public.company_members;
create trigger company_members_log_central_access after insert or update of role_id,primary_team_id,platform_status or delete on public.company_members
for each row execute function public.log_central_member_access_change();

create or replace function public.manage_company_role(
  target_company_id uuid,target_role_id uuid,target_name text,target_description text,target_permissions jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare role_row public.company_roles%rowtype; permission_value jsonb; permission_key_value text; scope_value text;
begin
  if not public.has_company_permission(target_company_id,'company.roles.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if nullif(trim(target_name),'') is null then raise exception 'role_name_required' using errcode='22023'; end if;
  if target_role_id is null then
    if not public.has_feature(target_company_id,'roles_permissions') then raise exception 'Votre offre ne permet pas encore de créer des rôles personnalisés.' using errcode='42501'; end if;
    insert into public.company_roles(company_id,role_key,name,description,is_system,created_by,updated_by)
    values(target_company_id,'custom-'||substr(replace(gen_random_uuid()::text,'-',''),1,16),trim(target_name),nullif(trim(target_description),''),false,auth.uid(),auth.uid()) returning * into role_row;
  else
    select * into role_row from public.company_roles where id=target_role_id and company_id=target_company_id for update;
    if role_row.id is null then raise exception 'role_not_found' using errcode='P0002'; end if;
    if role_row.is_system then raise exception 'Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.' using errcode='42501'; end if;
    update public.company_roles set name=trim(target_name),description=nullif(trim(target_description),''),updated_by=auth.uid(),updated_at=now()
    where id=target_role_id returning * into role_row;
    delete from public.company_role_permissions where role_id=role_row.id;
  end if;
  for permission_value in select value from jsonb_array_elements(coalesce(target_permissions,'[]'::jsonb)) loop
    permission_key_value:=permission_value->>'permission_key'; scope_value:=coalesce(permission_value->>'scope','company');
    if scope_value not in('own','team','company') or not exists(select 1 from public.permission_definitions definition
      where definition.permission_key=permission_key_value and definition.permission_key=definition.canonical_key
        and definition.active and scope_value=any(definition.allowed_scopes)) then
      raise exception 'invalid_role_permission:%',permission_key_value using errcode='22023';
    end if;
    insert into public.company_role_permissions(role_id,permission_key,scope,created_by,updated_by)
    values(role_row.id,permission_key_value,scope_value,auth.uid(),auth.uid());
  end loop;
  perform public.append_company_access_audit(target_company_id,case when target_role_id is null then 'role.created' else 'role.updated' end,
    'company_role',role_row.id::text,null,to_jsonb(role_row),null,auth.uid(),null);
  return jsonb_build_object('id',role_row.id,'name',role_row.name,'is_system',false);
end
$$;

create or replace function public.duplicate_company_role(target_company_id uuid,target_source_role_id uuid,target_name text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare source_row public.company_roles%rowtype; result_id uuid;
begin
  if not public.has_company_permission(target_company_id,'company.roles.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  if not public.has_feature(target_company_id,'roles_permissions') then raise exception 'Votre offre ne permet pas encore de créer des rôles personnalisés.' using errcode='42501'; end if;
  select * into source_row from public.company_roles where id=target_source_role_id and company_id=target_company_id and active;
  if source_row.id is null then raise exception 'role_not_found' using errcode='P0002'; end if;
  insert into public.company_roles(company_id,role_key,name,description,is_system,source_role_id,created_by,updated_by)
  values(target_company_id,'custom-'||substr(replace(gen_random_uuid()::text,'-',''),1,16),trim(target_name),source_row.description,false,source_row.id,auth.uid(),auth.uid()) returning id into result_id;
  insert into public.company_role_permissions(role_id,permission_key,scope,created_by,updated_by)
  select result_id,permission_key,scope,auth.uid(),auth.uid() from public.company_role_permissions where role_id=source_row.id;
  perform public.append_company_access_audit(target_company_id,'role.duplicated','company_role',result_id::text,to_jsonb(source_row),jsonb_build_object('name',target_name),null,auth.uid(),null);
  return result_id;
end
$$;

create or replace function public.delete_company_role(target_company_id uuid,target_role_id uuid,target_reason text default null)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare role_row public.company_roles%rowtype;
begin
  if not public.has_company_permission(target_company_id,'company.roles.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into role_row from public.company_roles where id=target_role_id and company_id=target_company_id for update;
  if role_row.is_system then raise exception 'Ce rôle n’est pas modifiable, il fait partie des rôles par défaut du logiciel.' using errcode='42501'; end if;
  if exists(select 1 from public.company_members where company_id=target_company_id and role_id=target_role_id and platform_status<>'removed') then raise exception 'Ce rôle est encore attribué à un utilisateur.' using errcode='23503'; end if;
  update public.company_roles set active=false,updated_by=auth.uid(),updated_at=now() where id=target_role_id;
  perform public.append_company_access_audit(target_company_id,'role.archived','company_role',target_role_id::text,to_jsonb(role_row),jsonb_build_object('active',false),target_reason,auth.uid(),null);
end
$$;

create or replace function public.manage_company_member(
  target_company_id uuid,target_user_id uuid,target_action text,target_role_id uuid default null,
  target_team_id uuid default null,target_reason text default null
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare member_row public.company_members%rowtype; previous_value jsonb; legacy_role text;
begin
  if not public.has_company_permission(target_company_id,'company.users.manage') then raise exception 'forbidden' using errcode='42501'; end if;
  select * into member_row from public.company_members where company_id=target_company_id and user_id=target_user_id for update;
  if member_row.user_id is null then raise exception 'member_not_found' using errcode='P0002'; end if;
  previous_value:=to_jsonb(member_row);
  if target_action='change_role' then
    select case system_key when 'administrator' then 'admin' when 'commercial' then 'sales' when 'accountant' then 'accounting' else 'member' end
      into legacy_role from public.company_roles where id=target_role_id and company_id=target_company_id and active;
    if legacy_role is null then raise exception 'role_not_found' using errcode='P0002'; end if;
    update public.company_members set role_id=target_role_id,role=case when role='owner' then 'owner' else legacy_role end,updated_at=now()
      where company_id=target_company_id and user_id=target_user_id;
  elsif target_action='suspend' then
    update public.company_members set platform_status='suspended',suspended_at=now(),suspension_reason=nullif(trim(target_reason),''),updated_at=now()
      where company_id=target_company_id and user_id=target_user_id;
  elsif target_action='reactivate' then
    update public.company_members set platform_status='active',suspended_at=null,suspension_reason=null,access_removed_at=null,access_removed_by=null,updated_at=now()
      where company_id=target_company_id and user_id=target_user_id;
  elsif target_action='remove' then
    update public.company_members set platform_status='removed',access_removed_at=now(),access_removed_by=auth.uid(),updated_at=now()
      where company_id=target_company_id and user_id=target_user_id;
  elsif target_action='set_team' then
    if target_team_id is not null and not exists(select 1 from public.company_teams where id=target_team_id and company_id=target_company_id and active) then raise exception 'team_not_found'; end if;
    update public.company_members set primary_team_id=target_team_id,updated_at=now() where company_id=target_company_id and user_id=target_user_id;
  else raise exception 'invalid_member_action' using errcode='22023'; end if;
  select * into member_row from public.company_members where company_id=target_company_id and user_id=target_user_id;
  insert into public.notifications(company_id,user_id,notification_type,title,message,entity_type,action_url,metadata,created_by)
  values(target_company_id,target_user_id,'access_changed','Vos accès ont été modifiés',
    'Un administrateur a modifié votre rôle ou votre statut dans l’entreprise.','company_member','#settings/users',jsonb_build_object('action',target_action),auth.uid());
  perform public.append_company_access_audit(target_company_id,'member.'||target_action,'company_member',target_user_id::text,previous_value,to_jsonb(member_row),target_reason,auth.uid(),null);
  return to_jsonb(member_row);
end
$$;

create or replace function public.list_my_pending_company_invitations()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare email_value text;
begin
  if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
  select lower(email) into email_value from auth.users where id=auth.uid();
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',invitation.id,'company_id',invitation.company_id,'company_name',company.name,
    'role_name',role.name,'expires_at',invitation.expires_at
  ) order by invitation.created_at)
  from public.company_invitations invitation
  join public.companies company on company.id=invitation.company_id
  join public.company_roles role on role.id=invitation.intended_role_id and role.active
  where lower(invitation.email)=email_value and invitation.status in('pending','sent') and invitation.expires_at>now()),'[]'::jsonb);
end
$$;

create or replace function public.accept_company_invitation(target_invitation_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare invitation_row public.company_invitations%rowtype; role_row public.company_roles%rowtype; email_value text; member_row public.company_members%rowtype;
  active_members integer:=0; maximum_members integer:=1; existing_member boolean:=false;
begin
  if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
  select lower(email) into email_value from auth.users where id=auth.uid();
  select * into invitation_row from public.company_invitations where id=target_invitation_id for update;
  if invitation_row.id is null or lower(invitation_row.email)<>email_value then raise exception 'invitation_not_found' using errcode='42501'; end if;
  if invitation_row.status not in('pending','sent') then raise exception 'invitation_already_used' using errcode='22023'; end if;
  if invitation_row.expires_at<=now() then
    update public.company_invitations set status='expired',token_hash=null,updated_at=now() where id=invitation_row.id;
    raise exception 'invitation_expired' using errcode='22023';
  end if;
  select * into role_row from public.company_roles where id=invitation_row.intended_role_id and company_id=invitation_row.company_id and active;
  if role_row.id is null then raise exception 'invitation_role_unavailable' using errcode='22023'; end if;
  select exists(select 1 from public.company_members member where member.company_id=invitation_row.company_id
    and member.user_id=auth.uid() and member.platform_status<>'removed') into existing_member;
  if not existing_member then
    select coalesce(subscription.max_users_override,plan.max_users,1) into maximum_members
    from public.subscriptions subscription left join public.plans plan on plan.key=subscription.plan_key
    where subscription.company_id=invitation_row.company_id limit 1;
    maximum_members:=coalesce(maximum_members,1);
    select count(*) into active_members from public.company_members member where member.company_id=invitation_row.company_id
      and member.platform_status in('pending','active','suspended');
    if active_members>=maximum_members then
      raise exception 'Votre offre autorise % utilisateur(s). Modifiez l’abonnement avant d’ajouter un membre.',maximum_members using errcode='23514';
    end if;
  end if;
  insert into public.company_members(company_id,user_id,role,role_id,primary_team_id,platform_status)
  values(invitation_row.company_id,auth.uid(),case role_row.system_key when 'administrator' then 'admin' when 'commercial' then 'sales' when 'accountant' then 'accounting' else 'member' end,
    role_row.id,invitation_row.intended_team_id,'active')
  on conflict(company_id,user_id) do update set role_id=excluded.role_id,primary_team_id=excluded.primary_team_id,platform_status='active',updated_at=now()
  returning * into member_row;
  update public.company_invitations set status='accepted',invited_user_id=auth.uid(),accepted_at=now(),token_hash=null,updated_at=now() where id=invitation_row.id;
  insert into public.user_preferences(user_id,company_id,onboarding_completed)
  values(auth.uid(),invitation_row.company_id,true)
  on conflict(user_id) do update set company_id=case when public.user_preferences.company_id is null then excluded.company_id else public.user_preferences.company_id end,updated_at=now();
  perform public.append_company_access_audit(invitation_row.company_id,'invitation.accepted','company_invitation',invitation_row.id::text,null,
    jsonb_build_object('user_id',auth.uid(),'role_id',invitation_row.intended_role_id),null,auth.uid(),null);
  return jsonb_build_object('accepted',true,'company_id',invitation_row.company_id,'role_id',member_row.role_id);
end
$$;

-- Kept only as a compatibility stub: joining a company now always requires an
-- explicit, authenticated confirmation through accept_company_invitation().
create or replace function public.accept_pending_company_invitations()
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
  return jsonb_build_object('accepted',0,'explicit_confirmation_required',true);
end
$$;

create or replace function public.list_company_access_users(
  target_company_id uuid,search_text text default null,status_filter text default null,role_filter uuid default null,
  invitation_filter text default null,sort_key text default 'added_at',sort_direction text default 'desc',
  page_number integer default 1,page_size integer default 25
) returns table(
  user_id uuid,email text,first_name text,last_name text,display_name text,role_id uuid,role_name text,
  role_is_system boolean,member_status text,last_sign_in_at timestamptz,added_at timestamptz,
  invitation_status text,invitation_id uuid,total_count bigint
) language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare normalized_search text:=nullif(trim(search_text),''); safe_page integer:=greatest(coalesce(page_number,1),1);
  safe_size integer:=least(greatest(coalesce(page_size,25),1),100); safe_sort text; safe_direction text;
begin
  if not public.has_company_permission(target_company_id,'company.users.read') then raise exception 'forbidden' using errcode='42501'; end if;
  safe_sort:=case when sort_key in('name','email','role','status','last_sign_in_at','added_at') then sort_key else 'added_at' end;
  safe_direction:=case when lower(sort_direction)='asc' then 'asc' else 'desc' end;
  return query execute format($query$
    with rows as (
      select member.user_id,auth_user.email::text,
        coalesce(preference.first_name,auth_user.raw_user_meta_data->>'first_name')::text first_name,
        coalesce(preference.last_name,auth_user.raw_user_meta_data->>'last_name')::text last_name,
        coalesce(preference.display_name,auth_user.raw_user_meta_data->>'full_name')::text display_name,
        member.role_id,role.name::text role_name,coalesce(role.is_system,false) role_is_system,
        member.platform_status::text member_status,auth_user.last_sign_in_at,member.created_at added_at,
        invitation.status::text invitation_status,invitation.id invitation_id
      from public.company_members member
      left join auth.users auth_user on auth_user.id=member.user_id
      left join public.user_preferences preference on preference.user_id=member.user_id
      left join public.company_roles role on role.id=member.role_id
      left join lateral (
        select candidate.* from public.company_invitations candidate
        where candidate.company_id=member.company_id and (candidate.invited_user_id=member.user_id or lower(candidate.email)=lower(auth_user.email))
        order by candidate.created_at desc limit 1
      ) invitation on true
      where member.company_id=$1
        and ($2 is null or concat_ws(' ',coalesce(preference.first_name,auth_user.raw_user_meta_data->>'first_name'),
          coalesce(preference.last_name,auth_user.raw_user_meta_data->>'last_name'),auth_user.email,role.name) ilike '%%'||$2||'%%')
        and ($3 is null or member.platform_status=$3)
        and ($4 is null or member.role_id=$4)
        and ($5 is null or coalesce(invitation.status,'none')=$5)
    )
    select rows.*,count(*) over() total_count from rows
    order by %s %s nulls last,user_id
    limit $6 offset $7
  $query$,case safe_sort when 'name' then 'coalesce(first_name,display_name,email)'
      when 'email' then 'email' when 'role' then 'role_name' when 'status' then 'member_status'
      when 'last_sign_in_at' then 'last_sign_in_at' else 'added_at' end,safe_direction)
  using target_company_id,normalized_search,nullif(status_filter,''),role_filter,nullif(invitation_filter,''),safe_size,(safe_page-1)*safe_size;
end
$$;

create or replace function public.get_company_access_context(target_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare can_manage boolean; result jsonb;
begin
  can_manage:=public.has_company_permission(target_company_id,'company.users.read');
  if not can_manage then raise exception 'forbidden' using errcode='42501'; end if;
  select jsonb_build_object(
    'summary',jsonb_build_object(
      'active_users',(select count(*) from public.company_members where company_id=target_company_id and platform_status='active'),
      'pending_invitations',(select count(*) from public.company_invitations where company_id=target_company_id and status in('pending','sent') and expires_at>now()),
      'custom_roles',(select count(*) from public.company_roles where company_id=target_company_id and not is_system and active),
      'anomalies',(select count(*) from public.company_members where company_id=target_company_id and role_id is null)
    ),
    'permissions',(select coalesce(jsonb_agg(to_jsonb(definition) order by definition.category_label,definition.position,definition.label),'[]'::jsonb)
      from public.permission_definitions definition where definition.active and definition.editor_visible),
    'roles',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',role.id,'role_key',role.role_key,'name',role.name,'description',role.description,'system_key',role.system_key,
      'is_system',role.is_system,'active',role.active,'created_at',role.created_at,'updated_at',role.updated_at,
      'users_count',(select count(*) from public.company_members member where member.company_id=target_company_id and member.role_id=role.id and member.platform_status<>'removed'),
      'permissions',(select coalesce(jsonb_agg(jsonb_build_object('permission_key',permission.permission_key,'scope',permission.scope)),'[]'::jsonb)
        from public.company_role_permissions permission where permission.role_id=role.id)
    ) order by role.is_system desc,role.name),'[]'::jsonb) from public.company_roles role where role.company_id=target_company_id and role.active),
    'users',(select coalesce(jsonb_agg(jsonb_build_object(
      'user_id',member.user_id,'email',auth_user.email,'first_name',coalesce(preference.first_name,auth_user.raw_user_meta_data->>'first_name'),
      'last_name',coalesce(preference.last_name,auth_user.raw_user_meta_data->>'last_name'),'display_name',coalesce(preference.display_name,auth_user.raw_user_meta_data->>'full_name'),
      'role_id',member.role_id,'legacy_role',member.role,'status',member.platform_status,'primary_team_id',member.primary_team_id,
      'last_sign_in_at',auth_user.last_sign_in_at,'added_at',member.created_at,'is_current',member.user_id=auth.uid()
    ) order by member.created_at),'[]'::jsonb) from public.company_members member
      left join auth.users auth_user on auth_user.id=member.user_id left join public.user_preferences preference on preference.user_id=member.user_id
      where member.company_id=target_company_id),
    'invitations',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',invitation.id,'email',invitation.email,'first_name',invitation.first_name,'last_name',invitation.last_name,
      'intended_role_id',invitation.intended_role_id,'intended_team_id',invitation.intended_team_id,'status',
      case when invitation.status in('pending','sent') and invitation.expires_at<=now() then 'expired' else invitation.status end,
      'delivery_status',invitation.delivery_status,'send_count',invitation.send_count,'last_sent_at',invitation.last_sent_at,
      'expires_at',invitation.expires_at,'created_at',invitation.created_at,'delivery_error',invitation.delivery_error
    ) order by invitation.created_at desc),'[]'::jsonb) from public.company_invitations invitation where invitation.company_id=target_company_id),
    'teams',(select coalesce(jsonb_agg(to_jsonb(team) order by team.name),'[]'::jsonb) from public.company_teams team where team.company_id=target_company_id and team.active),
    'audit',(select coalesce(jsonb_agg(to_jsonb(entry) order by entry.created_at desc,entry.id desc),'[]'::jsonb) from
      (select * from public.company_access_audit where company_id=target_company_id order by created_at desc,id desc limit 250) entry)
  ) into result;
  return result;
end
$$;

-- Automatically create the four roles for new companies.
create or replace function public.provision_company_access_roles()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin perform public.seed_company_access_roles(new.id); return new; end
$$;
drop trigger if exists companies_provision_access_roles on public.companies;
create trigger companies_provision_access_roles after insert on public.companies
for each row execute function public.provision_company_access_roles();

-- A single ownership convention powers the own/team/company scopes.
alter table public.clients add column if not exists team_id uuid references public.company_teams(id) on delete set null;
alter table public.opportunities add column if not exists team_id uuid references public.company_teams(id) on delete set null;
alter table public.activities add column if not exists team_id uuid references public.company_teams(id) on delete set null;
alter table public.reminders add column if not exists team_id uuid references public.company_teams(id) on delete set null;
alter table public.documents add column if not exists team_id uuid references public.company_teams(id) on delete set null;

-- These base tables deliberately use column-level SELECT grants to keep costs
-- and margins out of browser responses.  Expose only the new assignment
-- columns required by the scoped RLS policies; granting the whole table here
-- would undo that protection.
grant select(team_id) on public.clients,public.opportunities,public.activities,public.reminders,public.documents to authenticated;

update public.clients target set assigned_user_id=coalesce(target.assigned_user_id,target.created_by),
  team_id=coalesce(target.team_id,member.primary_team_id)
from public.company_members member where member.company_id=target.company_id
  and member.user_id=coalesce(target.assigned_user_id,target.created_by) and (target.assigned_user_id is null or target.team_id is null);
update public.opportunities target set assigned_user_id=coalesce(target.assigned_user_id,target.owner_user_id,target.created_by),
  owner_user_id=coalesce(target.owner_user_id,target.assigned_user_id,target.created_by),team_id=coalesce(target.team_id,member.primary_team_id)
from public.company_members member where member.company_id=target.company_id
  and member.user_id=coalesce(target.assigned_user_id,target.owner_user_id,target.created_by)
  and (target.assigned_user_id is null or target.owner_user_id is null or target.team_id is null);
update public.activities target set assigned_user_id=coalesce(target.assigned_user_id,target.created_by),team_id=coalesce(target.team_id,member.primary_team_id)
from public.company_members member where member.company_id=target.company_id
  and member.user_id=coalesce(target.assigned_user_id,target.created_by) and (target.assigned_user_id is null or target.team_id is null);
update public.reminders target set assigned_user_id=coalesce(target.assigned_user_id,target.created_by),team_id=coalesce(target.team_id,member.primary_team_id)
from public.company_members member where member.company_id=target.company_id
  and member.user_id=coalesce(target.assigned_user_id,target.created_by) and (target.assigned_user_id is null or target.team_id is null);
update public.documents target set assigned_user_id=coalesce(target.assigned_user_id,target.created_by),team_id=coalesce(target.team_id,member.primary_team_id)
from public.company_members member where member.company_id=target.company_id
  and member.user_id=coalesce(target.assigned_user_id,target.created_by) and (target.assigned_user_id is null or target.team_id is null);

create index if not exists clients_access_scope_idx on public.clients(company_id,assigned_user_id,team_id);
create index if not exists opportunities_access_scope_idx on public.opportunities(company_id,assigned_user_id,team_id);
create index if not exists activities_access_scope_idx on public.activities(company_id,assigned_user_id,team_id);
create index if not exists reminders_access_scope_idx on public.reminders(company_id,assigned_user_id,team_id);
create index if not exists documents_access_scope_idx on public.documents(company_id,document_type,assigned_user_id,team_id);

create or replace function public.document_read_permission(target_type text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case when target_type='quote' then 'sales.quotes.read'
    when target_type in('invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice','recurring_invoice') then 'sales.invoices.read'
    else 'application.read' end
$$;
revoke all on function public.document_read_permission(text) from public,anon;
grant execute on function public.document_read_permission(text) to authenticated;

create or replace function public.enforce_company_resource_permission()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare row_value record; actor uuid:=auth.uid(); permission_key text; owner_id uuid; resource_team_id uuid; member_team_id uuid;
  old_status text; new_status text; target_type text;
begin
  if actor is null then return case when tg_op='DELETE' then old else new end; end if;
  if tg_op='DELETE' then row_value:=old; else row_value:=new; end if;
  select primary_team_id into member_team_id from public.company_members
    where company_id=row_value.company_id and user_id=actor and platform_status='active';
  if tg_table_name='clients' then
    if tg_op<>'DELETE' then
      new.assigned_user_id:=coalesce(new.assigned_user_id,new.created_by,actor);
      new.team_id:=coalesce(new.team_id,member_team_id);
      owner_id:=new.assigned_user_id; resource_team_id:=new.team_id;
    else owner_id:=old.assigned_user_id; resource_team_id:=old.team_id; end if;
    permission_key:='clients.write';
  elsif tg_table_name='opportunities' then
    if tg_op<>'DELETE' then
      new.assigned_user_id:=coalesce(new.assigned_user_id,new.owner_user_id,new.created_by,actor);
      new.owner_user_id:=coalesce(new.owner_user_id,new.assigned_user_id);
      new.team_id:=coalesce(new.team_id,member_team_id);
      owner_id:=new.assigned_user_id; resource_team_id:=new.team_id;
    else owner_id:=coalesce(old.assigned_user_id,old.owner_user_id,old.created_by); resource_team_id:=old.team_id; end if;
    permission_key:='crm.opportunities.write';
  elsif tg_table_name='activities' then
    if tg_op<>'DELETE' then
      new.assigned_user_id:=coalesce(new.assigned_user_id,new.created_by,actor); new.team_id:=coalesce(new.team_id,member_team_id);
      owner_id:=new.assigned_user_id; resource_team_id:=new.team_id;
    else owner_id:=coalesce(old.assigned_user_id,old.created_by); resource_team_id:=old.team_id; end if;
    permission_key:='crm.activities.write';
  elsif tg_table_name='reminders' then
    if tg_op<>'DELETE' then
      new.assigned_user_id:=coalesce(new.assigned_user_id,new.created_by,actor); new.team_id:=coalesce(new.team_id,member_team_id);
      owner_id:=new.assigned_user_id; resource_team_id:=new.team_id;
    else owner_id:=coalesce(old.assigned_user_id,old.created_by); resource_team_id:=old.team_id; end if;
    permission_key:='crm.reminders.manage';
  elsif tg_table_name='documents' then
    if tg_op<>'DELETE' then
      new.assigned_user_id:=coalesce(new.assigned_user_id,new.created_by,actor); new.team_id:=coalesce(new.team_id,member_team_id);
      owner_id:=new.assigned_user_id; resource_team_id:=new.team_id; target_type:=new.document_type;
    else owner_id:=coalesce(old.assigned_user_id,old.created_by); resource_team_id:=old.team_id; target_type:=old.document_type; end if;
    old_status:=case when tg_op='INSERT' then null else old.status end;
    new_status:=case when tg_op='DELETE' then null else new.status end;
    if target_type='quote' then
      permission_key:=case when tg_op='INSERT' then 'sales.quotes.create'
        when tg_op='DELETE' then 'sales.quotes.update_draft'
        when old.number is distinct from new.number or old.validated_at is distinct from new.validated_at
          or (old_status='draft' and new_status<>'draft') then 'sales.quotes.finalize'
        when old.sent_at is distinct from new.sent_at then 'sales.quotes.send'
        else 'sales.quotes.update_draft' end;
    elsif target_type='credit_note' then permission_key:='sales.credit_notes.create';
    elsif target_type in('invoice','deposit_invoice','balance_invoice','proforma_invoice','recurring_invoice') then
      permission_key:=case when tg_op='INSERT' then 'sales.invoices.create_draft'
        when tg_op='DELETE' then 'sales.invoices.update_draft'
        when old.number is distinct from new.number or old.finalized_at is distinct from new.finalized_at
          or old.validated_at is distinct from new.validated_at or (old_status='draft' and new_status<>'draft') then 'sales.invoices.finalize'
        when old.sent_at is distinct from new.sent_at then 'sales.invoices.send'
        when old_status<>'draft' and new_status is distinct from old_status
          and (public.has_company_permission(row_value.company_id,'payments.create') or public.has_company_permission(row_value.company_id,'payments.cancel')) then null
        else 'sales.invoices.update_draft' end;
    else permission_key:='application.read'; end if;
  end if;
  if permission_key is not null and not public.has_company_permission(row_value.company_id,permission_key,'own',owner_id,resource_team_id) then
    raise exception 'permission_denied:%',permission_key using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;

drop trigger if exists clients_enforce_central_permission on public.clients;
create trigger clients_enforce_central_permission before insert or update or delete on public.clients
  for each row execute function public.enforce_company_resource_permission();
drop trigger if exists opportunities_enforce_central_permission on public.opportunities;
create trigger opportunities_enforce_central_permission before insert or update or delete on public.opportunities
  for each row execute function public.enforce_company_resource_permission();
drop trigger if exists activities_enforce_central_permission on public.activities;
create trigger activities_enforce_central_permission before insert or update or delete on public.activities
  for each row execute function public.enforce_company_resource_permission();
drop trigger if exists reminders_enforce_central_permission on public.reminders;
create trigger reminders_enforce_central_permission before insert or update or delete on public.reminders
  for each row execute function public.enforce_company_resource_permission();
drop trigger if exists documents_enforce_central_permission on public.documents;
create trigger documents_enforce_central_permission before insert or update or delete on public.documents
  for each row execute function public.enforce_company_resource_permission();

create or replace function public.enforce_document_line_permission()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare document_row public.documents%rowtype; target_id uuid; permission_key text;
begin
  if auth.uid() is null then return case when tg_op='DELETE' then old else new end; end if;
  target_id:=case when tg_op='DELETE' then old.document_id else new.document_id end;
  select * into document_row from public.documents where id=target_id;
  if document_row.id is null then raise exception 'document_not_found' using errcode='23503'; end if;
  permission_key:=case when document_row.document_type='quote' then 'sales.quotes.update_draft'
    when document_row.document_type='credit_note' then 'sales.credit_notes.create'
    when document_row.document_type in('invoice','deposit_invoice','balance_invoice','proforma_invoice','recurring_invoice') then 'sales.invoices.update_draft'
    else 'application.read' end;
  if document_row.status<>'draft' or document_row.number is not null and document_row.document_type<>'quote' then
    raise exception 'document_locked' using errcode='42501';
  end if;
  if not public.has_company_permission(document_row.company_id,permission_key,'own',coalesce(document_row.assigned_user_id,document_row.created_by),document_row.team_id) then
    raise exception 'permission_denied:%',permission_key using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists document_lines_enforce_central_permission on public.document_lines;
create trigger document_lines_enforce_central_permission before insert or update or delete on public.document_lines
  for each row execute function public.enforce_document_line_permission();

create or replace function public.enforce_payment_permission()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare row_value public.payments%rowtype; permission_key text;
begin
  if auth.uid() is null then return case when tg_op='DELETE' then old else new end; end if;
  row_value:=case when tg_op='DELETE' then old else new end;
  permission_key:=case when coalesce(row_value.entry_type,'payment') in('correction','refund') or tg_op='DELETE' then 'payments.cancel' else 'payments.create' end;
  if not public.has_company_permission(row_value.company_id,permission_key) then
    raise exception 'permission_denied:%',permission_key using errcode='42501';
  end if;
  return case when tg_op='DELETE' then old else new end;
end
$$;
drop trigger if exists payments_enforce_central_permission on public.payments;
create trigger payments_enforce_central_permission before insert or update or delete on public.payments
  for each row execute function public.enforce_payment_permission();

-- Restrictive policies are combined with the existing tenant policies. They
-- reduce visibility to the central role scope instead of replacing tenancy.
drop policy if exists clients_central_scope_select on public.clients;
create policy clients_central_scope_select on public.clients as restrictive for select to authenticated using(
  public.has_company_permission(company_id,'clients.read','own',coalesce(assigned_user_id,created_by),team_id));
drop policy if exists opportunities_central_scope_select on public.opportunities;
create policy opportunities_central_scope_select on public.opportunities as restrictive for select to authenticated using(
  public.has_company_permission(company_id,'crm.opportunities.read','own',coalesce(assigned_user_id,owner_user_id,created_by),team_id));
drop policy if exists activities_central_scope_select on public.activities;
create policy activities_central_scope_select on public.activities as restrictive for select to authenticated using(
  public.has_company_permission(company_id,'crm.activities.read','own',coalesce(assigned_user_id,created_by),team_id));
drop policy if exists reminders_central_scope_select on public.reminders;
create policy reminders_central_scope_select on public.reminders as restrictive for select to authenticated using(
  public.has_company_permission(company_id,'crm.reminders.manage','own',coalesce(assigned_user_id,created_by),team_id)
  or public.has_company_permission(company_id,'sales.receivables.read','own',coalesce(assigned_user_id,created_by),team_id));
drop policy if exists documents_central_scope_select on public.documents;
create policy documents_central_scope_select on public.documents as restrictive for select to authenticated using(
  public.has_company_permission(company_id,public.document_read_permission(document_type),'own',coalesce(assigned_user_id,created_by),team_id));
drop policy if exists document_lines_central_scope_select on public.document_lines;
create policy document_lines_central_scope_select on public.document_lines as restrictive for select to authenticated using(exists(
  select 1 from public.documents document where document.id=document_id and document.company_id=document_lines.company_id
    and public.has_company_permission(document.company_id,public.document_read_permission(document.document_type),'own',
      coalesce(document.assigned_user_id,document.created_by),document.team_id)));
drop policy if exists payments_central_scope_select on public.payments;
create policy payments_central_scope_select on public.payments as restrictive for select to authenticated using(exists(
  select 1 from public.documents document where document.id=document_id and document.company_id=payments.company_id
    and public.has_company_permission(document.company_id,'payments.read','own',coalesce(document.assigned_user_id,document.created_by),document.team_id)));
drop policy if exists payment_schedules_central_scope_select on public.payment_schedules;
create policy payment_schedules_central_scope_select on public.payment_schedules as restrictive for select to authenticated using(exists(
  select 1 from public.documents document where document.id=document_id and document.company_id=payment_schedules.company_id
    and public.has_company_permission(document.company_id,'sales.receivables.read','own',coalesce(document.assigned_user_id,document.created_by),document.team_id)));

-- Tighten direct member mutations: all management now passes through audited RPCs.
drop policy if exists company_members_insert_admin on public.company_members;
drop policy if exists company_members_update_admin on public.company_members;
drop policy if exists company_members_delete_admin on public.company_members;

alter table public.permission_definitions enable row level security;
alter table public.company_roles enable row level security;
alter table public.company_role_permissions enable row level security;
alter table public.company_teams enable row level security;
alter table public.company_team_members enable row level security;
alter table public.company_invitations enable row level security;
alter table public.company_access_audit enable row level security;

drop policy if exists permission_definitions_read on public.permission_definitions;
create policy permission_definitions_read on public.permission_definitions for select to authenticated using(active);
drop policy if exists company_roles_read on public.company_roles;
create policy company_roles_read on public.company_roles for select to authenticated using(public.is_company_member(company_id));
drop policy if exists company_role_permissions_read on public.company_role_permissions;
create policy company_role_permissions_read on public.company_role_permissions for select to authenticated using(exists(
  select 1 from public.company_roles role where role.id=role_id and public.is_company_member(role.company_id)));
drop policy if exists company_teams_read on public.company_teams;
create policy company_teams_read on public.company_teams for select to authenticated using(public.is_company_member(company_id));
drop policy if exists company_team_members_read on public.company_team_members;
create policy company_team_members_read on public.company_team_members for select to authenticated using(public.is_company_member(company_id));
drop policy if exists company_invitations_read on public.company_invitations;
create policy company_invitations_read on public.company_invitations for select to authenticated using(public.has_company_permission(company_id,'company.users.read'));
drop policy if exists company_access_audit_read on public.company_access_audit;
create policy company_access_audit_read on public.company_access_audit for select to authenticated using(public.has_company_permission(company_id,'company.users.read'));

revoke all on table public.permission_definitions,public.company_roles,public.company_role_permissions,
  public.company_teams,public.company_team_members,public.company_invitations,public.company_access_audit from anon,authenticated;
grant select on table public.permission_definitions,public.company_roles,public.company_role_permissions,
  public.company_teams,public.company_team_members,public.company_invitations,public.company_access_audit to authenticated;

revoke all on function public.manage_company_role(uuid,uuid,text,text,jsonb) from public,anon;
revoke all on function public.duplicate_company_role(uuid,uuid,text) from public,anon;
revoke all on function public.delete_company_role(uuid,uuid,text) from public,anon;
revoke all on function public.manage_company_member(uuid,uuid,text,uuid,uuid,text) from public,anon;
revoke all on function public.accept_pending_company_invitations() from public,anon;
revoke all on function public.list_my_pending_company_invitations() from public,anon;
revoke all on function public.accept_company_invitation(uuid) from public,anon;
revoke all on function public.list_company_access_users(uuid,text,text,uuid,text,text,text,integer,integer) from public,anon;
revoke all on function public.get_company_access_context(uuid) from public,anon;
grant execute on function public.manage_company_role(uuid,uuid,text,text,jsonb) to authenticated;
grant execute on function public.duplicate_company_role(uuid,uuid,text) to authenticated;
grant execute on function public.delete_company_role(uuid,uuid,text) to authenticated;
grant execute on function public.manage_company_member(uuid,uuid,text,uuid,uuid,text) to authenticated;
grant execute on function public.accept_pending_company_invitations() to authenticated;
grant execute on function public.list_my_pending_company_invitations() to authenticated;
grant execute on function public.accept_company_invitation(uuid) to authenticated;
grant execute on function public.list_company_access_users(uuid,text,text,uuid,text,text,text,integer,integer) to authenticated;
grant execute on function public.get_company_access_context(uuid) to authenticated;

commit;
