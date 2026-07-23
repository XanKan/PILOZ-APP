const fs=require('node:fs');
const path=require('node:path');

const packageRoot=process.env.PILOZ_PGLITE_ROOT;
if(!packageRoot)throw new Error('PILOZ_PGLITE_ROOT is required');
const {PGlite}=require(path.join(packageRoot,'dist','index.cjs'));
const repoRoot=path.resolve(__dirname,'..');
const migrationsDir=path.join(repoRoot,'supabase','migrations');
const actor='11111111-1111-4111-8111-111111111111';
const company='22222222-2222-4222-8222-222222222222';
const supplier='33333333-3333-4333-8333-333333333333';
const client='44444444-4444-4444-8444-444444444444';
const outsider='55555555-5555-4555-8555-555555555555';
const otherCompany='66666666-6666-4666-8666-666666666666';
const warehouseA='77777777-7777-4777-8777-777777777777';
const warehouseB='88888888-8888-4888-8888-888888888888';
let catalogStage='startup';

function compatibleMigration(sql){
  // PGlite exposes gen_random_uuid in core but does not package pgcrypto.
  // The compatibility digest is sufficient to compile and exercise migrations;
  // production Supabase continues to use the real pgcrypto SHA-256 function.
  return sql.replace(/create\s+extension\s+(?:if\s+not\s+exists\s+)?pgcrypto(?:\s+with\s+schema\s+extensions)?\s*;/gi,'');
}

async function main(){
 let stage=catalogStage='bootstrap';
 const db=new PGlite();
 await db.exec(`
  create role anon nologin; create role authenticated nologin; create role service_role nologin; create role supabase_admin nologin;
  create schema auth; create schema storage; create schema extensions;
  create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}'::jsonb);
  create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  create or replace function extensions.digest(data bytea,algorithm text) returns bytea language sql immutable as $$ select decode(md5(encode(data,'hex')),'hex') $$;
  create or replace function public.digest(data bytea,algorithm text) returns bytea language sql immutable as $$ select extensions.digest(data,algorithm) $$;
  create table storage.buckets(id text primary key,name text not null unique,public boolean default false,file_size_limit bigint,allowed_mime_types text[]);
  create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text not null,name text not null,owner uuid,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now(),unique(bucket_id,name));
  create or replace function storage.foldername(name text) returns text[] language sql immutable as $$ select case when position('/' in name)>0 then string_to_array(regexp_replace(name,'/[^/]+$',''),'/') else array[]::text[] end $$;
  alter table storage.objects enable row level security;
 `);
 for(const file of fs.readdirSync(migrationsDir).filter(name=>name.endsWith('.sql')).sort()){
  try{await db.exec(compatibleMigration(fs.readFileSync(path.join(migrationsDir,file),'utf8')));}
  catch(error){error.message=`Migration ${file}: ${error.message}`;throw error;}
 }
 await db.exec(`
  insert into auth.users(id,email) values('${actor}','catalogue@piloz.fr');
  insert into public.companies(id,owner_user_id,name) values('${company}','${actor}','Société catalogue');
  insert into public.company_members(company_id,user_id,role) values('${company}','${actor}','owner');
  insert into public.company_settings(company_id,legal_name,siret,email,address_line1,postal_code,city,onboarding_completed_at) values('${company}','Société catalogue','12345678900011','catalogue@piloz.fr','1 rue du Test','75001','Paris',now());
  update public.company_document_settings set quote_prefix='DEV',invoice_prefix='FAC' where company_id='${company}';
  insert into auth.users(id,email) values('${outsider}','autre@piloz.fr');
  insert into public.companies(id,owner_user_id,name) values('${otherCompany}','${outsider}','Autre société');
  insert into public.company_members(company_id,user_id,role) values('${otherCompany}','${outsider}','owner');
  insert into public.catalog_items(company_id,item_type,reference,name,created_by) values('${otherCompany}','product','AUTRE-001','Article isolé','${outsider}');
  insert into public.suppliers(id,company_id,legal_name,created_by) values('${supplier}','${company}','Fournitures Pro','${actor}');
  insert into public.clients(id,company_id,kind,legal_name,created_by) values('${client}','${company}','company','Client tarif','${actor}');
  insert into public.warehouses(id,company_id,code,name,created_by) values('${warehouseA}','${company}','A','Entrepôt A','${actor}'),('${warehouseB}','${company}','B','Entrepôt B','${actor}');
  set request.jwt.claim.sub='${actor}'; set role authenticated;
 `);
 stage=catalogStage='references';
 const ref1=(await db.query(`select public.next_catalog_reference($1,'product') value`,[company])).rows[0].value;
 const ref2=(await db.query(`select public.next_catalog_reference($1,'product') value`,[company])).rows[0].value;
 if(ref1!=='ART-000001'||ref2!=='ART-000002')throw new Error(`Références atomiques invalides: ${ref1}, ${ref2}`);
 stage=catalogStage='create';
 const create=(await db.query(`select public.create_catalog_item($1,$2::jsonb,$3::jsonb,$4::jsonb) id`,[
  company,JSON.stringify({item_type:'product',name:'Perceuse',purchase_price:100,landing_cost:10,cost_price:110,sale_price:180,tax_rate:20,stock_managed:true,aliases:['perfo']}),
  JSON.stringify([{supplier_id:supplier,supplier_reference:'FP-18V',purchase_price:100,is_primary:true}]),
  JSON.stringify([{name:'Bleu',reference:'ART-BLEU',attribute_values:{Couleur:'Bleu'},sale_price:190}])
 ])).rows[0].id;
 await db.exec('reset role');
 const row=(await db.query(`select reference,cost_price,status from public.catalog_items where id=$1`,[create])).rows[0];
 if(row.reference!=='ART-000003'||Number(row.cost_price)!==110||row.status!=='active')throw new Error('Création complète invalide');
 const supplierCount=Number((await db.query(`select count(*) value from public.supplier_items where catalog_item_id=$1`,[create])).rows[0].value);
 const variantCount=Number((await db.query(`select count(*) value from public.item_variants where item_id=$1`,[create])).rows[0].value);
 const historyCount=Number((await db.query(`select count(*) value from public.item_price_history where item_id=$1`,[create])).rows[0].value);
 if(supplierCount!==1||variantCount!==1||historyCount!==1)throw new Error('Relations catalogue incomplètes');
 const matrixCount=Number((await db.query(`select public.create_catalog_variants($1,$2::jsonb,$3::jsonb) value`,[
  create,JSON.stringify([{name:'Taille',values:['S','M'],position:0}]),JSON.stringify([
   {name:'S',reference:'ART-S',attribute_values:{Taille:'S'},sale_price:210,tax_rate:20},
   {name:'M',reference:'ART-M',attribute_values:{Taille:'M'},sale_price:215,tax_rate:20}
  ])
 ])).rows[0].value);
 if(matrixCount!==2)throw new Error('Génération atomique de matrice invalide');
 stage=catalogStage='stock-operations';
 await db.query(`select public.post_stock_movement($1,$2,'opening',10,'unité',null,$3,null,null,'Stock initial',null,110)`,[company,create,warehouseA]);
 const transfer=(await db.query(`select public.transfer_catalog_stock($1,4,'unité',$2,$3,null,null,null,'Transfert test') id`,[create,warehouseA,warehouseB])).rows[0].id;
 const reservation=(await db.query(`select public.reserve_catalog_stock($1,$2,2,'test',$3,null,null) id`,[create,warehouseB,'99999999-9999-4999-8999-999999999999'])).rows[0].id;
 await db.query(`select public.release_catalog_reservation($1,'Test terminé')`,[reservation]);
 const transferRow=(await db.query(`select transfer_group_id from public.stock_movements where id=$1`,[transfer])).rows[0];
 const reservationRow=(await db.query(`select status from public.stock_reservations where id=$1`,[reservation])).rows[0];
 if(!transferRow.transfer_group_id||reservationRow.status!=='released')throw new Error('Transfert ou réservation de stock invalide');
 stage=catalogStage='price-change';await db.exec('set role authenticated');
 await db.query(`select public.change_catalog_price($1,120,10,210,current_date,'Tarif été','manual')`,[create]);
 await db.exec('reset role');
 const price=(await db.query(`select purchase_price,cost_price,sale_price from public.catalog_items where id=$1`,[create])).rows[0];
 if(Number(price.purchase_price)!==120||Number(price.cost_price)!==130||Number(price.sale_price)!==210)throw new Error('Historisation des prix invalide');
 stage=catalogStage='price-list';await db.exec('set role authenticated');
 const list=(await db.query(`insert into public.price_lists(company_id,name,client_id,priority,created_by) values($1,'Tarif client',$2,10,$3) returning id`,[company,client,actor])).rows[0].id;
 const listItem=(await db.query(`insert into public.price_list_items(company_id,price_list_id,item_id,fixed_price,created_by) values($1,$2,$3,175,$4) returning id`,[company,list,create,actor])).rows[0].id;
 await db.query(`insert into public.price_tiers(company_id,price_list_item_id,min_quantity,fixed_price,created_by) values($1,$2,10,165,$3)`,[company,listItem,actor]);
 const resolved=(await db.query(`select * from public.resolve_catalog_price($1,$2,12,current_date,null)`,[create,client])).rows[0];
 if(Number(resolved.unit_price)!==165||resolved.source!=='Grille tarifaire')throw new Error('Résolution de grille tarifaire invalide');
 stage=catalogStage='snapshot';await db.exec('reset role');
 const document=(await db.query(`insert into public.documents(company_id,document_type,status,issue_date,client_id,created_by) values($1,'quote','draft',current_date,$2,$3) returning id`,[company,client,actor])).rows[0].id;
 await db.query(`insert into public.document_lines(company_id,document_id,position,line_type,item_id,reference,name,quantity,unit,unit_cost_snapshot,unit_price,tax_rate,line_metadata,created_by) values($1,$2,1,'item',$3,'ART-000003','Perceuse',2,'unité',130,165,20,jsonb_build_object('price_list_id',$4::text),$5)`,[company,document,create,list,actor]);
 const snapshot=(await db.query(`select line_metadata->'catalog_snapshot' value from public.document_lines where document_id=$1`,[document])).rows[0].value;
 if(snapshot.item_id!==create||snapshot.price_list_id!==list)throw new Error('Snapshot de ligne incomplet');
 stage=catalogStage='isolation';await db.exec('set role authenticated');
 const visible=Number((await db.query(`select count(*) value from public.catalog_items`)).rows[0].value);
 if(visible!==1)throw new Error(`Isolation RLS invalide: ${visible} ligne(s) visibles`);
 const authorization=(await db.query(`select public.can_manage_catalog($1,'catalog_delete') allowed`,[company])).rows[0];
 if(!authorization.allowed)throw new Error('Permission catalogue invalide pour le propriétaire');
 const restrictedColumns=(await db.query(`select
   has_column_privilege('authenticated','public.supplier_items','purchase_price','select') supplier_cost,
   has_column_privilege('authenticated','public.item_variants','cost_price','select') variant_cost,
   has_column_privilege('authenticated','public.item_price_history','new_cost_price','select') history_cost`)).rows[0];
 if(restrictedColumns.supplier_cost||restrictedColumns.variant_cost||restrictedColumns.history_cost)throw new Error('Une colonne de coût sensible reste lisible directement');
 const financial=(await db.query(`select public.get_company_financial_fields($1) value`,[company])).rows[0].value;
 if(!financial.supplier_items?.length||!financial.item_variants?.length||!financial.item_price_history?.length)throw new Error('Restitution financière autorisée incomplète');
 const configuredUnits=(await db.query(`select units from public.company_catalog_settings where company_id=$1`,[company])).rows[0]?.units||[];
 if(!configuredUnits.includes('unité')||!configuredUnits.includes('heure'))throw new Error('Unités du catalogue non initialisées');
 let directDeleteBlocked=false;
 try{await db.query(`delete from public.catalog_items where id=$1`,[create]);}catch(error){directDeleteBlocked=true;}
 directDeleteBlocked=directDeleteBlocked&&Boolean((await db.query(`select exists(select 1 from public.catalog_items where id=$1) value`,[create])).rows[0].value);
 if(!directDeleteBlocked)throw new Error('La suppression SQL directe d’un article utilisé n’est pas bloquée');
 stage=catalogStage='archive';const archived=(await db.query(`select public.archive_or_delete_catalog_item($1,true) value`,[create])).rows[0].value;
 if(archived!=='archived_used_item')throw new Error('Protection de suppression invalide');
 await db.exec('reset role');
 const policies=(await db.query(`select count(*) value from pg_policies where schemaname='public' and tablename in('item_variants','item_price_history','price_lists','item_notes')`)).rows[0].value;
 console.log(JSON.stringify({ok:true,schema_version:'202607230051',reference_sequence:[ref1,ref2,row.reference],item_id:create,relations:{suppliers:supplierCount,variants:variantCount+matrixCount,price_history:historyCount},stock:{transfer:true,reservation_release:true},resolved_price:Number(resolved.unit_price),snapshot:true,units:configuredUnits.length,tenant_rows_visible:visible,sensitive_cost_columns_restricted:true,deletion_guard:{direct_delete_blocked:directDeleteBlocked,rpc_result:archived},rls_policies:Number(policies),stage}));
 await db.close();
}
main().catch(error=>{console.error(`Étape ${catalogStage}: ${error.stack||error.message}`);process.exitCode=1;});
