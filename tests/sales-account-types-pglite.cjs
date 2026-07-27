const {loadPGlite,bootstrap,setIdentity}=require('./helpers/pglite-bootstrap.cjs');

const actor='a9000000-0000-4000-8000-000000000001';
const company='c9000000-0000-4000-8000-000000000001';
const client='d9000000-0000-4000-8000-000000000001';

async function main(){
  const {PGlite,pgcrypto}=loadPGlite(),db=new PGlite({extensions:{pgcrypto}});
  await bootstrap(db);
  await db.query('insert into auth.users(id,email) values($1,$2)',[actor,'sales-types@piloz.fr']);
  await db.query('insert into public.companies(id,owner_user_id,name) values($1,$2,$3)',[company,actor,'Entreprise comptes de vente']);
  await db.query("insert into public.company_members(company_id,user_id,role) values($1,$2,'owner')",[company,actor]);
  await db.query(`insert into public.company_settings(
    company_id,legal_name,legal_form,social_capital,siren,siret,vat_number,address_line1,postal_code,city,country,email,
    subject_to_vat,default_vat_rate,onboarding_completed_at
  ) values($1,'Entreprise comptes de vente','SARL',1000,'123456789','12345678900012','FR00123456789',
    '1 rue du Test','75001','Paris','France','compta@example.test',true,20,now())`,[company]);
  await db.query("insert into public.company_document_settings(company_id,invoice_prefix,default_payment_terms,default_payment_method) values($1,'FAC','days_30','bank_transfer') on conflict(company_id) do nothing",[company]);
  await db.query("insert into public.clients(id,company_id,kind,legal_name,email,address_line_1,postal_code,city,country_code,created_by) values($1,$2,'company','CLIENT TEST','client@example.test','2 rue Client','69001','Lyon','FR',$3)",[client,company,actor]);
  await setIdentity(db,actor);

  const mappings=(await db.query(`select scope_value,account_code from public.accounting_account_mappings
    where company_id=$1 and direction='sale' and scope_type='item_type' and active order by scope_value`,[company])).rows;
  const expectedMappings={fee:'708000',product:'707000',service:'706000',subscription:'706000'};
  if(JSON.stringify(Object.fromEntries(mappings.map(row=>[row.scope_value,row.account_code])))!==JSON.stringify(expectedMappings))
    throw new Error(`Comptes de vente par défaut invalides ${JSON.stringify(mappings)}`);
  if(mappings.some(row=>['package','pack','kit','discount','remise','comment','commentaire'].includes(row.scope_value)))
    throw new Error(`Un ancien type comptable est encore configuré ${JSON.stringify(mappings)}`);
  const aliases=['Main d’œuvre',"Main d'oeuvre",'main oeuvre','labor','service'];
  for(const alias of aliases){
    const canonical=(await db.query('select public.canonical_catalog_item_type($1) result',[alias])).rows[0].result;
    if(canonical!=='service')throw new Error(`Le type Main d’œuvre n’est pas reconnu pour ${alias}: ${canonical}`);
  }
  await db.exec('reset role');
  const laborLabel=(await db.query("select public.sales_account_type_label('service') result")).rows[0].result;
  if(laborLabel!=='Main d’œuvre')throw new Error(`Libellé utilisateur incorrect : ${laborLabel}`);
  await setIdentity(db,actor);
  const validation=(await db.query('select public.validate_sales_account_type_mappings($1) result',[company])).rows[0].result;
  if(!validation?.ok)throw new Error(`Configuration comptable annoncée incomplète ${JSON.stringify(validation)}`);
  const accountingFunction=(await db.query(
    "select pg_get_functiondef('public._generate_document_accounting_entry(uuid)'::regprocedure) definition"
  )).rows[0].definition;
  if(accountingFunction.includes('piloz_sales_account_totals')||!accountingFunction.includes('sales_account_totals jsonb'))
    throw new Error('Le moteur comptable utilise encore une relation temporaire incompatible avec Supabase db lint.');

  const itemIds={product:crypto.randomUUID(),service:crypto.randomUUID(),subscription:crypto.randomUUID(),fee:crypto.randomUUID(),package:crypto.randomUUID()};
  await db.exec('reset role');
  await db.query(`insert into public.catalog_items(id,company_id,item_type,reference,name,unit,sale_price,tax_rate,active,created_by) values
    ($1,$5,'product','ART-TEST','Ordinateur','unité',900,20,true,$6),
    ($2,$5,'service','SER-TEST','Installation','unité',500,20,true,$6),
    ($3,$5,'subscription','ABO-TEST','Abonnement','mois',50,20,true,$6),
    ($4,$5,'fee','FRAIS-TEST','Frais','unité',25,20,true,$6)`,[itemIds.product,itemIds.service,itemIds.subscription,itemIds.fee,company,actor]);
  let obsoleteInsertBlocked=false;
  try{await db.query("insert into public.catalog_items(id,company_id,item_type,reference,name,unit,sale_price,tax_rate,active,created_by) values($1,$2,'comment','COMMENT-TEST','Ancien commentaire','unité',0,0,true,$3)",[crypto.randomUUID(),company,actor]);}catch(error){obsoleteInsertBlocked=String(error.message).includes('catalog_item_type_not_selectable');}
  if(!obsoleteInsertBlocked)throw new Error('La création d’un ancien type de catalogue est encore autorisée.');
  await setIdentity(db,actor);
  const apiLaborId=(await db.query(`select public.create_catalog_item($1,$2::jsonb,'[]'::jsonb,'[]'::jsonb) result`,[
    company,JSON.stringify({item_type:'Main d’œuvre',name:'Pose par API',unit:'heure',sale_price:75,tax_rate:20,stock_managed:true})
  ])).rows[0].result;
  const apiLabor=(await db.query('select item_type,stock_managed from public.catalog_items where id=$1',[apiLaborId])).rows[0];
  if(apiLabor?.item_type!=='service'||apiLabor?.stock_managed!==false)
    throw new Error(`Le type Main d’œuvre n’est pas normalisé par l’API ${JSON.stringify(apiLabor)}`);

  const baseDocument=subject=>({company_id:company,document_type:'invoice',version:1,client_id:client,issue_date:'2026-07-27',due_date:'2026-08-26',subject,currency:'EUR',language:'fr',sale_type:'goods_and_services',payment_terms:'days_30',payment_method:'bank_transfer',discount_rate:0,deposit_rate:0,pipeline_stage:'draft',metadata:{pipeline_stage:'draft'}});
  const line=(position,itemId,name,price,type,extra={})=>({id:crypto.randomUUID(),position,line_type:type||'item',item_id:itemId||null,name,quantity:1,unit:'unité',unit_price:price,unit_cost_snapshot:0,discount_rate:0,tax_rate:20,optional:false,line_metadata:{accounting_item_type:extra.accounting_item_type||'service'},...extra});
  async function finalize(subject,lines,documentPatch={}){
    const saved=(await db.query('select public.save_document_draft(null,$1::jsonb,$2::jsonb) result',[JSON.stringify({...baseDocument(subject),...documentPatch}),JSON.stringify(lines)])).rows[0].result;
    await db.query('select public.finalize_document($1)',[saved.id]);
    const entry=(await db.query("select id from public.accounting_entries where document_id=$1 and event_kind='original'",[saved.id])).rows[0];
    if(!entry)throw new Error(`Écriture absente pour ${subject}`);
    return{documentId:saved.id,entryId:entry.id,lines:(await db.query('select account_code,account_label,debit,credit,third_party_id from public.accounting_entry_lines where entry_id=$1 order by line_number',[entry.id])).rows};
  }

  const grouped=await finalize('Regroupement par compte',[
    line(1,itemIds.service,'Installation',500,'item',{accounting_item_type:'service'}),
    line(2,itemIds.product,'Ordinateur',900,'item',{accounting_item_type:'product'}),
    line(3,itemIds.service,'Formation',300,'item',{accounting_item_type:'service'}),
    {id:crypto.randomUUID(),position:4,line_type:'comment',name:'Commentaire sans écriture',quantity:0,unit:'unité',unit_price:0,discount_rate:0,tax_rate:0,optional:false,line_metadata:{}}
  ]);
  const grouped706=grouped.lines.filter(row=>row.account_code==='706000'),grouped707=grouped.lines.filter(row=>row.account_code==='707000'),groupedVat=grouped.lines.filter(row=>row.account_code==='445712');
  if(grouped706.length!==1||Number(grouped706[0].credit)!==800||grouped707.length!==1||Number(grouped707[0].credit)!==900||groupedVat.length!==1||Number(groupedVat[0].credit)!==340)
    throw new Error(`Regroupement comptable invalide ${JSON.stringify(grouped.lines)}`);
  if(grouped.lines.some(row=>/comment/i.test(row.account_label||'')))throw new Error('Un commentaire a généré une écriture comptable.');

  const singleProduct=await finalize('Facture Article',[line(1,itemIds.product,'Article seul',100,'item',{accounting_item_type:'product'})]);
  const singleLabor=await finalize('Facture Main d’œuvre',[line(1,itemIds.service,'Main d’œuvre seule',100,'item',{accounting_item_type:'service'})]);
  if(Number(singleProduct.lines.find(row=>row.account_code==='707000')?.credit)!==100)
    throw new Error(`Facture Article mal ventilée ${JSON.stringify(singleProduct.lines)}`);
  if(Number(singleLabor.lines.find(row=>row.account_code==='706000')?.credit)!==100)
    throw new Error(`Facture Main d’œuvre mal ventilée ${JSON.stringify(singleLabor.lines)}`);

  const discounted=await finalize('Remise rattachée au service',[
    line(1,itemIds.service,'Service remisé',100,'item',{accounting_item_type:'service',discount_rate:20})
  ]);
  const discounted706=discounted.lines.filter(row=>row.account_code==='706000');
  if(discounted706.length!==1||Number(discounted706[0].credit)!==80||discounted.lines.some(row=>row.account_code==='665'))
    throw new Error(`Remise imputée sur un compte séparé ${JSON.stringify(discounted.lines)}`);

  const globalDiscount=await finalize('Remise globale ventilée',[
    line(1,itemIds.service,'Service',100,'item',{accounting_item_type:'service'}),
    line(2,itemIds.product,'Article',100,'item',{accounting_item_type:'product'})
  ],{discount_rate:10});
  const global706=globalDiscount.lines.find(row=>row.account_code==='706000'),global707=globalDiscount.lines.find(row=>row.account_code==='707000');
  if(Number(global706?.credit)!==90||Number(global707?.credit)!==90||globalDiscount.lines.some(row=>row.account_code==='665'))
    throw new Error(`Remise globale non ventilée au prorata ${JSON.stringify(globalDiscount.lines)}`);

  const recurringAndFees=await finalize('Abonnement et frais',[
    line(1,itemIds.subscription,'Abonnement',50,'item',{accounting_item_type:'subscription'}),
    line(2,itemIds.fee,'Frais',25,'item',{accounting_item_type:'fee'})
  ]);
  const recurring706=recurringAndFees.lines.find(row=>row.account_code==='706000'),fees708=recurringAndFees.lines.find(row=>row.account_code==='708000');
  if(Number(recurring706?.credit)!==50||Number(fees708?.credit)!==25)
    throw new Error(`Abonnement ou frais mal ventilé ${JSON.stringify(recurringAndFees.lines)}`);

  await db.exec('reset role');
  await db.exec('alter table public.catalog_items drop constraint catalog_items_item_type_check');
  await db.exec("set session_replication_role='replica'");
  await db.query("insert into public.catalog_items(id,company_id,item_type,reference,name,unit,sale_price,tax_rate,active,created_by) values($1,$2,'package','PACK-LEGACY','Pack historique','unité',1400,20,true,$3)",[itemIds.package,company,actor]);
  await db.exec("set session_replication_role='origin'");
  await db.exec("alter table public.catalog_items add constraint catalog_items_item_type_check check(item_type in('product','service','subscription','fee')) not valid");
  await db.query(`insert into public.item_bundle_components(company_id,bundle_item_id,component_item_id,quantity,position,created_by)
    values($1,$2,$3,1,1,$5),($1,$2,$4,1,2,$5)`,[company,itemIds.package,itemIds.service,itemIds.product,actor]);
  await setIdentity(db,actor);
  const packed=await finalize('Pack ventilé par composants',[line(1,itemIds.package,'Pack historique',1400,'item',{accounting_item_type:'service'})]);
  const packed706=packed.lines.find(row=>row.account_code==='706000'),packed707=packed.lines.find(row=>row.account_code==='707000');
  if(!packed706||!packed707||packed.lines.some(row=>row.account_code==='701000'))
    throw new Error(`Pack non ventilé par composants ${JSON.stringify(packed.lines)}`);

  await db.exec('reset role');
  await db.query("delete from public.accounting_account_mappings where company_id=$1 and direction='sale' and scope_type='item_type' and scope_value='fee'",[company]);
  await setIdentity(db,actor);
  const missing=(await db.query('select public.validate_sales_account_type_mappings($1) result',[company])).rows[0].result;
  if(missing?.ok||!missing?.missing?.some(row=>row.key==='fee'))throw new Error(`Compte manquant non détecté ${JSON.stringify(missing)}`);
  let exportBlocked=false;
  try{await db.query("select public.preview_accounting_export($1,'sales','2026-07-01','2026-07-31','csv_debit_credit',false)",[company]);}catch(error){exportBlocked=String(error.message).includes('accounting_sales_accounts_missing');}
  if(!exportBlocked)throw new Error('L’export reste possible avec un compte de vente manquant.');

  await db.close();
  console.log(JSON.stringify({ok:true,mappings,labor:{label:laborLabel,api_type:apiLabor.item_type,account:'706000'},grouped:{sales706:Number(grouped706[0].credit),sales707:Number(grouped707[0].credit),vat:Number(groupedVat[0].credit)},discount:Number(discounted706[0].credit),globalDiscount:{service:Number(global706.credit),product:Number(global707.credit)},subscription:Number(recurring706.credit),fees:Number(fees708.credit),pack:{service:Number(packed706.credit),product:Number(packed707.credit)},validation:missing}));
}

main().catch(error=>{console.error(error);process.exit(1);});
