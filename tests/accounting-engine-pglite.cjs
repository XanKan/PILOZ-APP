const {loadPGlite,bootstrap,setIdentity}=require('./helpers/pglite-bootstrap.cjs');

const actor='a2000000-0000-4000-8000-000000000001';
const company='c2000000-0000-4000-8000-000000000001';
const client='d2000000-0000-4000-8000-000000000001';
const otherActor='a2000000-0000-4000-8000-000000000002';
const otherCompany='c2000000-0000-4000-8000-000000000002';

async function main(){
  const {PGlite,pgcrypto}=loadPGlite(),db=new PGlite({extensions:{pgcrypto}});
  await bootstrap(db);
  await db.query('insert into auth.users(id,email) values($1,$2),($3,$4)',[actor,'accounting-engine@piloz.fr',otherActor,'other-company@piloz.fr']);
  await db.query('insert into public.companies(id,owner_user_id,name) values($1,$2,$3)',[company,actor,'Entreprise TVA multiple']);
  await db.query('insert into public.companies(id,owner_user_id,name) values($1,$2,$3)',[otherCompany,otherActor,'Entreprise isolée']);
  await db.query("insert into public.company_members(company_id,user_id,role) values($1,$2,'owner')",[company,actor]);
  await db.query("insert into public.company_members(company_id,user_id,role) values($1,$2,'owner')",[otherCompany,otherActor]);
  await db.query(`insert into public.company_settings(
      company_id,legal_name,legal_form,social_capital,siren,siret,vat_number,address_line1,postal_code,city,country,email,
      subject_to_vat,default_vat_rate,onboarding_completed_at
    ) values($1,'Entreprise TVA multiple','SARL',1000,'123456789','12345678900012','FR00123456789',
      '1 rue du Test','75001','Paris','France','compta@example.test',true,20,now())`,[company]);
  await db.query("insert into public.company_document_settings(company_id,invoice_prefix,default_payment_terms,default_payment_method) values($1,'FAC','days_30','bank_transfer') on conflict(company_id) do nothing",[company]);
  await db.query("insert into public.clients(id,company_id,kind,legal_name,email,address_line_1,postal_code,city,country_code,created_by) values($1,$2,'company','Client TVA multiple','client@example.test','2 rue Client','69001','Lyon','FR',$3)",[client,company,actor]);
  const ownConnection=crypto.randomUUID(),otherConnection=crypto.randomUUID();
  await db.query("insert into public.external_connections(id,company_id,user_id,provider,connection_scope,status,created_by) values($1,$2,$3,'gmail','personal','connected',$3),($4,$5,$6,'gmail','personal','connected',$6)",[ownConnection,company,actor,otherConnection,otherCompany,otherActor]);
  await db.query("insert into public.external_connection_secrets(connection_id,ciphertext,initialization_vector,key_version) values($1,'cipher-a','iv-a','v1'),($2,'cipher-b','iv-b','v1')",[ownConnection,otherConnection]);
  await db.query("insert into public.external_mail_links(company_id,connection_id,direction,subject,recipients,status,created_by) values($1,$2,'outbound','Message A',array['a@example.test'],'sent',$3),($4,$5,'outbound','Message B',array['b@example.test'],'sent',$6)",[company,ownConnection,actor,otherCompany,otherConnection,otherActor]);
  await db.query("insert into public.sales_terms(company_id,name,created_by) values($1,'CGV A',$2),($3,'CGV B',$4)",[company,actor,otherCompany,otherActor]);
  await setIdentity(db,actor);
  await db.query("select public.save_company_numbering_configuration($1,'DEV',73,'year_prefix','FAC',42,'prefix_year_month','AV',30)",[company]);

  const visibleConnections=(await db.query('select company_id,user_id from public.external_connections order by company_id')).rows;
  const visibleMail=(await db.query('select company_id,subject from public.external_mail_links order by company_id')).rows;
  const visibleTerms=(await db.query('select company_id,name from public.sales_terms order by company_id')).rows;
  if(visibleConnections.length!==1||visibleConnections[0].company_id!==company||visibleMail.length!==1||visibleMail[0].company_id!==company||visibleTerms.length!==1||visibleTerms[0].company_id!==company)
    throw new Error(`Isolation RLS entreprise A/B invalide ${JSON.stringify({visibleConnections,visibleMail,visibleTerms})}`);
  let secretBlocked=false;
  try{await db.query('select connection_id from public.external_connection_secrets');}catch{secretBlocked=true;}
  if(!secretBlocked)throw new Error('Les secrets OAuth sont lisibles par le navigateur.');

  const document={
    company_id:company,document_type:'invoice',version:1,client_id:client,
    issue_date:'2026-07-26',due_date:'2026-08-25',subject:'Facture multi-taux',
    currency:'EUR',language:'fr',sale_type:'goods_and_services',payment_terms:'days_30',
    payment_method:'bank_transfer',discount_rate:0,deposit_rate:0,pipeline_stage:'draft',metadata:{pipeline_stage:'draft'}
  };
  const lines=[
    {id:crypto.randomUUID(),position:1,line_type:'free_item',name:'Prestation 20 %',quantity:1,unit:'unité',unit_price:100,unit_cost_snapshot:0,discount_rate:0,tax_rate:20,optional:false,line_metadata:{}},
    {id:crypto.randomUUID(),position:2,line_type:'free_item',name:'Prestation 10 %',quantity:1,unit:'unité',unit_price:100,unit_cost_snapshot:0,discount_rate:0,tax_rate:10,optional:false,line_metadata:{}}
  ];
  const draft=(await db.query('select public.save_document_draft(null,$1::jsonb,$2::jsonb) result',[JSON.stringify(document),JSON.stringify(lines)])).rows[0].result;
  const finalized=(await db.query('select public.finalize_document($1) result',[draft.id])).rows[0].result;
  if(!finalized?.number)throw new Error('La facture multi-taux n’a pas été finalisée.');
  if(finalized.number!=='FAC-2026-07-0042')throw new Error(`Premier numéro configuré non respecté : ${finalized.number}`);
  let invoiceNumberingLocked=false;
  try{await db.query("select public.save_company_numbering_configuration($1,'DEV',73,'year_prefix','FAC',99,'prefix_year_month','AV',30)",[company]);}catch(error){invoiceNumberingLocked=String(error.message).includes('invoice_numbering_locked');}
  if(!invoiceNumberingLocked)throw new Error('La séquence facture reste modifiable après une facture.');
  await db.query("select public.save_company_numbering_configuration($1,'DEV',74,'prefix_year','FAC',43,'prefix_year_month','AV',30)",[company]);

  await db.exec('reset role');
  await db.query("update public.company_document_settings set quote_next_number=2 where company_id=$1",[company]);
  await db.query("update public.document_sequences set next_value=2 where company_id=$1 and document_type='quote' and year=2026",[company]);
  await db.exec('alter table public.documents disable trigger user');
  await db.query(`insert into public.documents(company_id,document_type,number,client_id,status,issue_date,validity_date,currency,language,total_excl_tax,total_tax,total_incl_tax,created_by)
    values($1,'quote','DEV-2026-0077',$2,'pending','2026-07-26','2026-08-25','EUR','fr',100,20,120,$3)`,[company,client,actor]);
  await db.exec('alter table public.documents enable trigger user');
  await db.exec("set session_replication_role='replica'");
  await db.query("update public.documents set number='DEV-2026-0077' where company_id=$1 and document_type='quote'",[company]);
  await db.exec("set session_replication_role='origin'");
  await db.exec('reset role');
  const historicalQuote=(await db.query("select number,issue_date,document_type,public._piloz_existing_document_sequence_max(company_id,'quote',2026) existing_max from public.documents where company_id=$1 and document_type='quote'",[company])).rows;
  const reconciledQuoteNumber=(await db.query("select public._piloz_take_document_number($1,'quote',2026,false) number",[company])).rows[0].number;
  const reconciledQuoteNext=Number((await db.query('select quote_next_number from public.company_document_settings where company_id=$1',[company])).rows[0].quote_next_number);
  if(reconciledQuoteNumber!=='DEV-2026-0078'||reconciledQuoteNext!==79)
    throw new Error(`Reconciliation de la sequence devis invalide ${JSON.stringify({historicalQuote,reconciledQuoteNumber,reconciledQuoteNext})}`);
  await setIdentity(db,actor);

  const entry=(await db.query("select id from public.accounting_entries where document_id=$1 and event_kind='original'",[draft.id])).rows[0];
  if(!entry)throw new Error('Écriture comptable de facture absente.');
  const totals=(await db.query('select round(sum(debit),2) debit,round(sum(credit),2) credit from public.accounting_entry_lines where entry_id=$1',[entry.id])).rows[0];
  if(Number(totals.debit)!==230||Number(totals.credit)!==230)throw new Error(`Écriture déséquilibrée ${JSON.stringify(totals)}`);
  const vatLines=(await db.query("select account_code,tax_rate,credit from public.accounting_entry_lines where entry_id=$1 and account_code like '4457%' order by tax_rate",[entry.id])).rows;
  const vat10=vatLines.find(row=>Number(row.tax_rate)===10),vat20=vatLines.find(row=>Number(row.tax_rate)===20);
  if(vat10?.account_code!=='445713'||Number(vat10.credit)!==10||vat20?.account_code!=='445712'||Number(vat20.credit)!==20)
    throw new Error(`Ventilation TVA incorrecte ${JSON.stringify(vatLines)}`);

  const preview=(await db.query("select public.preview_accounting_export($1,'sales','2026-07-01','2026-07-31','csv_debit_credit',false) result",[company])).rows[0].result;
  if(!preview?.ok||!preview.entries?.every(row=>row.balanced)||Number(preview.entry_count)!==1)throw new Error(`Prévisualisation comptable invalide ${JSON.stringify(preview)}`);
  const firstExport=(await db.query("select public.validate_accounting_export($1,'sales','2026-07-01','2026-07-31','csv_debit_credit',false,false,'Test export fige') id",[company])).rows[0].id;
  const frozen=(await db.query("select status,entry_count,total_debit,total_credit,snapshot_sha256 from public.accounting_export_batches where id=$1",[firstExport])).rows[0];
  const frozenFile=(await db.query("select content_text,sha256 from public.accounting_export_files where export_batch_id=$1 and file_kind='entries'",[firstExport])).rows[0];
  if(frozen.status!=='validated'||Number(frozen.entry_count)!==1||Number(frozen.total_debit)!==230||Number(frozen.total_credit)!==230||!frozen.snapshot_sha256)
    throw new Error(`Export valide incomplet ${JSON.stringify(frozen)}`);
  if(!frozenFile?.content_text?.startsWith('Journal;Date;Ecriture;Piece;Compte;')||!frozenFile.sha256)
    throw new Error('Le CSV generique ne possede pas sa structure documentee.');
  const excluded=(await db.query("select public.preview_accounting_export($1,'sales','2026-07-01','2026-07-31','csv_debit_credit',false) result",[company])).rows[0].result;
  if(Number(excluded.entry_count)!==0||excluded.accounts.length!==0)throw new Error('Une ecriture validee reste exportable.');
  const cancellation=(await db.query("select public.cancel_accounting_export($1,'Correction du lot de test') id",[firstExport])).rows[0].id;
  if(!cancellation)throw new Error('Annulation tracable de export absente.');
  const released=(await db.query("select public.preview_accounting_export($1,'sales','2026-07-01','2026-07-31','fec_technical',false) result",[company])).rows[0].result;
  if(Number(released.entry_count)!==1||released.fec_status!=='Revue comptable requise')throw new Error('Reexport apres annulation indisponible ou statut FEC trompeur.');

  const paymentRequest=crypto.randomUUID();
  const receipt=(await db.query(`select public.record_multi_invoice_payment(
      $1::jsonb,115,'bank_transfer','2026-07-26T10:00:00Z',null,'VIR-TEST','BANK-TEST','Reglement partiel',null,'{}'::jsonb,null,false,$2
    ) result`,[JSON.stringify([{document_id:draft.id,amount:115}]),paymentRequest])).rows[0].result;
  const paymentId=(await db.query('select id from public.payments where payment_receipt_id=$1',[receipt.receipt_id])).rows[0]?.id;
  if(!paymentId)throw new Error('Reglement securise absent.');
  const paymentEntry=(await db.query("select id from public.accounting_entries where payment_id=$1 and source_type='payment'",[paymentId])).rows[0];
  if(!paymentEntry)throw new Error('Ecriture comptable du reglement absente.');
  const paymentTotals=(await db.query('select round(sum(debit),2) debit,round(sum(credit),2) credit from public.accounting_entry_lines where entry_id=$1',[paymentEntry.id])).rows[0];
  if(Number(paymentTotals.debit)!==115||Number(paymentTotals.credit)!==115)throw new Error(`Reglement desequilibre ${JSON.stringify(paymentTotals)}`);
  const bankPreview=(await db.query("select public.preview_accounting_export($1,'bank','2026-07-01','2026-07-31','csv_aux_separate',true) result",[company])).rows[0].result;
  if(Number(bankPreview.entry_count)!==1||!bankPreview.entries[0]?.balanced)throw new Error('Journal de banque incomplet.');
  const vatPreview=(await db.query("select public.preview_vat_cash_collection($1,'2026-07-01','2026-07-31',true) result",[company])).rows[0].result;
  const vat10Collected=vatPreview.lines.find(row=>Number(row.tax_rate)===10),vat20Collected=vatPreview.lines.find(row=>Number(row.tax_rate)===20);
  if(Number(vatPreview.total_collected)!==115||Number(vatPreview.total_tax_base)!==100||Number(vatPreview.total_vat)!==15||
    Number(vat10Collected?.tax_base)!==50||Number(vat10Collected?.vat)!==5||Number(vat20Collected?.tax_base)!==50||Number(vat20Collected?.vat)!==10)
    throw new Error(`Ventilation TVA sur encaissement incorrecte ${JSON.stringify(vatPreview)}`);

  const legacyValid=crypto.randomUUID(),legacyInvalid=crypto.randomUUID();
  await db.exec('reset role');
  await db.exec("set session_replication_role='replica'");
  await db.query(`insert into public.documents(id,company_id,document_type,number,client_id,status,issue_date,due_date,subject,currency,language,total_excl_tax,total_tax,total_incl_tax,created_by)
    values($1,$2,'invoice','FAC-2026-07-0040',$3,'paid','2026-07-25','2026-08-25','Facture historique valide','EUR','fr',50,0,50,$4),
          ($5,$2,'invoice','FAC-2026-07-0039',$3,'finalized','2026-07-24','2026-08-24','Facture historique TVA incomplete','EUR','fr',100,20,120,$4)`,[legacyValid,company,client,actor,legacyInvalid]);
  await db.query(`insert into public.document_lines(company_id,document_id,position,line_type,name,quantity,unit,unit_price,tax_rate,total_excl_tax,total_tax,total_incl_tax,created_by)
    values($1,$2,1,'free_item','Ancienne prestation',1,'unité',50,0,50,0,50,$4),
          ($1,$3,1,'free_item','Ancienne prestation TVA',1,'unité',100,20,100,0,100,$4)`,[company,legacyValid,legacyInvalid,actor]);
  await db.exec("set session_replication_role='origin'");
  await setIdentity(db,actor);
  const backfill=(await db.query('select public.backfill_company_accounting_entries($1) result',[company])).rows[0].result;
  if(Number(backfill.created)!==1||Number(backfill.failed)!==1||!backfill.failures?.some(item=>item.number==='FAC-2026-07-0039'))
    throw new Error(`Rattrapage historique non diagnostique ${JSON.stringify(backfill)}`);
  const diagnostic=(await db.query("select public.diagnose_accounting_export($1,'sales','2026-07-01','2026-07-31') result",[company])).rows[0].result;
  if(Number(diagnostic.eligible_documents)!==3||Number(diagnostic.generated_entries)!==2||Number(diagnostic.missing_entries)!==1)
    throw new Error(`Diagnostic export incomplet ${JSON.stringify(diagnostic)}`);
  const previewAfterBackfill=(await db.query("select public.preview_accounting_export($1,'sales','2026-07-01','2026-07-31','fec_technical',false) result",[company])).rows[0].result;
  if(!previewAfterBackfill.entries.some(row=>row.piece_reference==='FAC-2026-07-0040'))
    throw new Error('La facture historique valide reste absente de la previsualisation.');

  const audit=(await db.query("select count(*)::int count from public.accounting_config_history where company_id=$1 and table_name in('accounting_settings','accounting_fiscal_years')",[company])).rows[0];
  if(Number(audit.count)<2)throw new Error('Historique des paramètres comptables incomplet.');

  await db.close();
  console.log(JSON.stringify({ok:true,documentNumber:finalized.number,reconciledQuoteNumber,reconciledQuoteNext,entryId:entry.id,totals,vatLines,
    export:{firstExport,cancellation,releasedEntries:released.entry_count},payment:{paymentId,totals:paymentTotals},
    vatCash:{collected:vatPreview.total_collected,base:vatPreview.total_tax_base,vat:vatPreview.total_vat,rates:vatPreview.lines.map(row=>row.tax_rate)},backfill,diagnostic,
    rls:{connections:visibleConnections.length,mail:visibleMail.length,terms:visibleTerms.length,secretsBlocked:secretBlocked}}));
}

main().catch(error=>{console.error(error);process.exit(1);});
