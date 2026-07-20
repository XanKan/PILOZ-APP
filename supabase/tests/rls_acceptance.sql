-- À exécuter avec Supabase CLI contre une base de test après les migrations.
begin;
select plan(19);
select has_table('public','companies','companies existe');
select has_table('public','documents','documents existe');
select has_table('public','stock_movements','stock_movements existe');
select has_function('public','next_document_number',array['uuid','text','integer'],'numérotation atomique disponible');
select has_function('public','validate_invoice',array['uuid'],'validation de facture disponible');
select has_function('public','confirm_sales_order',array['uuid','uuid'],'réservation atomique disponible');
select has_function('public','validate_goods_receipt',array['uuid'],'réception atomique disponible');
select has_function('public','validate_inventory_count',array['uuid'],'inventaire atomique disponible');
select has_table('public','supplier_quote_requests','demandes de prix disponibles');
select has_table('public','supplier_returns','retours fournisseurs disponibles');
select has_function('public','validate_delivery',array['uuid'],'livraison atomique disponible');
select has_function('public','reverse_stock_movement',array['uuid','text'],'correction de mouvement disponible');
select has_function('public','validate_supplier_return',array['uuid'],'retour fournisseur atomique disponible');
select has_function('public','confirm_purchase_order',array['uuid'],'confirmation achat atomique disponible');
select has_function('public','get_company_financial_fields',array['uuid'],'champs financiers protégés par permission');
select ok((select relrowsecurity from pg_class where oid='public.stock_movements'::regclass),'RLS active sur les mouvements');
select ok((select relrowsecurity from pg_class where oid='public.documents'::regclass),'RLS active sur les documents');

-- Test comportemental avec deux locataires et un JWT simulé.
insert into public.companies(id,owner_user_id,name) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Locataire A'),
 ('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','Locataire B');
insert into public.company_members(company_id,user_id,role) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','owner'),
 ('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','owner');
insert into public.clients(id,company_id,legal_name,created_by) values
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Client A','20000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Client B','20000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',true);
set local role authenticated;
select is((select count(*) from public.clients where id in('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002')),1::bigint,'un membre ne voit que le client de son entreprise');
select is((select count(*) from public.clients where id='30000000-0000-0000-0000-000000000002'),0::bigint,'le client du second locataire est inaccessible');
reset role;
select * from finish();
rollback;
