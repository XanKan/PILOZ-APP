begin;

-- Rebuild only missing rows inside explicitly tagged demo tenants. No real
-- company can be affected by this migration.
insert into public.clients(company_id,kind,legal_name,email,phone_e164,address_line_1,postal_code,city,country_code,payment_terms,created_by)
select company.id,'company','Nova Bâtiment','contact@nova-batiment.example','+33100000001','12 rue du Chantier','75012','Paris','FR','30 jours',company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.clients client where client.company_id=company.id and client.legal_name='Nova Bâtiment');

insert into public.clients(company_id,kind,legal_name,email,phone_e164,address_line_1,postal_code,city,country_code,payment_terms,created_by)
select company.id,'company','Atelier Horizon','bonjour@atelier-horizon.example','+33100000002','4 place des Artisans','44000','Nantes','FR','À réception',company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.clients client where client.company_id=company.id and client.legal_name='Atelier Horizon');

insert into public.clients(company_id,kind,first_name,last_name,email,phone_e164,postal_code,city,country_code,created_by)
select company.id,'person','Camille','Martin','camille.martin@example.com','+33100000003','69002','Lyon','FR',company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.clients client where client.company_id=company.id and client.email='camille.martin@example.com');

insert into public.catalog_items(company_id,item_type,reference,name,short_description,unit,purchase_price,sale_price,tax_rate,stock_managed,created_by)
select company.id,'service','DEMO-SRV-001','Audit organisationnel','Diagnostic et recommandations','forfait',350,750,20,false,company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.catalog_items item where item.company_id=company.id and item.reference='DEMO-SRV-001');

insert into public.catalog_items(company_id,item_type,reference,name,short_description,unit,purchase_price,sale_price,tax_rate,stock_managed,created_by)
select company.id,'subscription','DEMO-ABO-001','Accompagnement mensuel','Suivi et pilotage mensuels','mois',250,590,20,false,company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.catalog_items item where item.company_id=company.id and item.reference='DEMO-ABO-001');

insert into public.catalog_items(company_id,item_type,reference,name,short_description,unit,purchase_price,sale_price,tax_rate,stock_managed,created_by)
select company.id,'product','DEMO-ART-001','Kit de démarrage','Matériel de démonstration','unité',420,690,20,false,company.owner_user_id
from public.companies company
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.catalog_items item where item.company_id=company.id and item.reference='DEMO-ART-001');

insert into public.activities(company_id,client_id,activity_type,subject,description,scheduled_at,assigned_user_id,created_by,metadata)
select company.id,client.id,'call','Appeler Nova Bâtiment','Préparer la proposition commerciale (donnée fictive).',now()+interval '1 day',company.owner_user_id,company.owner_user_id,jsonb_build_object('demo',true)
from public.companies company
join public.clients client on client.company_id=company.id and client.legal_name='Nova Bâtiment'
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.activities activity where activity.company_id=company.id and activity.subject='Appeler Nova Bâtiment' and activity.metadata @> '{"demo":true}'::jsonb);

insert into public.activities(company_id,client_id,activity_type,subject,description,scheduled_at,assigned_user_id,created_by,metadata)
select company.id,client.id,'meeting','Rendez-vous Atelier Horizon','Présentation de la solution (donnée fictive).',now()+interval '7 days',company.owner_user_id,company.owner_user_id,jsonb_build_object('demo',true)
from public.companies company
join public.clients client on client.company_id=company.id and client.legal_name='Atelier Horizon'
where company.admin_tags @> array['demo']::text[]
  and not exists(select 1 from public.activities activity where activity.company_id=company.id and activity.subject='Rendez-vous Atelier Horizon' and activity.metadata @> '{"demo":true}'::jsonb);

commit;
