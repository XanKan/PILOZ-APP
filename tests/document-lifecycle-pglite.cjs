const fs=require('node:fs');
const path=require('node:path');

const packageRoot=process.env.PILOZ_PGLITE_ROOT;
if(!packageRoot)throw new Error('PILOZ_PGLITE_ROOT is required');
const {PGlite}=require(path.join(packageRoot,'dist','index.cjs'));
const {pgcrypto}=require(path.join(packageRoot,'dist','contrib','pgcrypto.cjs'));

const repoRoot=path.resolve(__dirname,'..');
const migrationsDir=path.join(repoRoot,'supabase','migrations');
const actor='11111111-1111-4111-8111-111111111111';
const company='22222222-2222-4222-8222-222222222222';
const client='33333333-3333-4333-8333-333333333333';

async function bootstrap(db){
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    create role supabase_admin nologin;
    create schema auth;
    create schema storage;
    create schema extensions;
    create extension pgcrypto with schema extensions;
    create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb default '{}'::jsonb);
    create or replace function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
    $$;
    create table storage.buckets(
      id text primary key,name text not null unique,public boolean default false,
      file_size_limit bigint,allowed_mime_types text[]
    );
    create table storage.objects(
      id uuid primary key default gen_random_uuid(),bucket_id text not null,name text not null,
      owner uuid,metadata jsonb,created_at timestamptz default now(),updated_at timestamptz default now(),
      unique(bucket_id,name)
    );
    create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
      select case when position('/' in name)>0 then string_to_array(regexp_replace(name,'/[^/]+$',''),'/') else array[]::text[] end
    $$;
    alter table storage.objects enable row level security;
  `);
  for(const file of fs.readdirSync(migrationsDir).filter(name=>name.endsWith('.sql')).sort()){
    try{await db.exec(fs.readFileSync(path.join(migrationsDir,file),'utf8'));}
    catch(error){error.message=`Migration ${file}: ${error.message}`;throw error;}
  }
  await db.exec(`
    insert into auth.users(id,email,raw_user_meta_data) values('${actor}','test@piloz.fr',jsonb_build_object('first_name','Alex'));
    insert into public.companies(id,owner_user_id,name) values('${company}','${actor}','Société Test');
    insert into public.company_members(company_id,user_id,role) values('${company}','${actor}','owner');
    insert into public.company_settings(company_id,legal_name,siren,siret,address_line1,postal_code,city,country,email,subject_to_vat,default_vat_rate,onboarding_completed_at)
      values('${company}','Société Test','123456789','12345678900012','1 rue du Test','75001','Paris','France','contact@piloz.fr',true,20,now())
      on conflict(company_id) do update set legal_name=excluded.legal_name;
    insert into public.company_document_settings(company_id,quote_prefix,invoice_prefix,credit_prefix,default_payment_terms,default_payment_method,quote_validity_days)
      values('${company}','DEV','FAC','AV','days_30','bank_transfer',30)
      on conflict(company_id) do nothing;
    insert into public.clients(id,company_id,kind,legal_name,email,siren,address_line_1,postal_code,city,country_code,customer_category,created_by)
      values('${client}','${company}','company','Client Test','client@piloz.fr','987654321','2 rue Client','69001','Lyon','FR','b2b','${actor}');
    set request.jwt.claim.sub='${actor}';
    set role authenticated;
  `);
}

async function saveDraft(db,type,existingId=null,unitPrice=100){
  const targetDocument={
    company_id:company,document_type:type,version:1,client_id:client,issue_date:'2026-07-21',
    due_date:type==='quote'?null:'2026-08-20',validity_date:type==='quote'?'2026-08-20':null,
    subject:type==='quote'?'Devis de test':'Facture de test',currency:'EUR',language:'fr',
    sale_type:'services',
    payment_terms:'days_30',payment_method:'bank_transfer',discount_rate:0,deposit_rate:0,
    pipeline_stage:'draft',metadata:{pipeline_stage:'draft'}
  };
  const targetLines=[{
    id:crypto.randomUUID(),
    position:1,line_type:'free_item',name:'Prestation de test',description:'Ligne réelle',quantity:1,
    unit:'unité',unit_cost_snapshot:50,unit_price:unitPrice,discount_rate:0,tax_rate:20,optional:false,
    cumulative_progress_percent:0,line_metadata:{}
  }];
  const draft=await db.query(
    'select public.save_document_draft($1,$2::jsonb,$3::jsonb) result',
    [existingId,JSON.stringify(targetDocument),JSON.stringify(targetLines)]
  );
  const saved=draft.rows[0].result;
  const expectedStatus=existingId?null:(type==='quote'?'pending':'draft');
  if(!saved?.id||(type==='quote'&&!saved.number)||(type!=='quote'&&saved.number)||(expectedStatus&&saved.status!==expectedStatus))throw new Error(`${type}: invalid draft result ${JSON.stringify(saved)}`);
  const totals=await db.query('select total_excl_tax,total_tax,total_incl_tax from public.documents where id=$1',[saved.id]);
  const total=Number(totals.rows[0]?.total_incl_tax||0);
  const expectedTotal=Math.round((unitPrice*1.2)*100)/100;
  if(total!==expectedTotal)throw new Error(`${type}: expected total ${expectedTotal}, got ${total}`);
  return {id:saved.id,number:saved.number,total,status:saved.status};
}

(async()=>{
  const db=new PGlite({extensions:{pgcrypto}});
  try{
    await bootstrap(db);
    await db.exec('reset role');
    await db.exec(`
      insert into public.document_templates(id,company_id,name,document_type,language,status,is_default,current_version,created_by,updated_by)
      values
        ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','${company}','Ancien devis','quote','fr','active',false,1,'${actor}','${actor}'),
        ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','${company}','Ancienne facture','invoice','fr','active',false,1,'${actor}','${actor}'),
        ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','${company}','Old English quote','quote','en','active',false,1,'${actor}','${actor}');
      select public._piloz_seed_document_templates('${company}','${actor}');
    `);
    const activeTemplates=await db.query(`
      select document_type,name,is_default from public.document_templates
      where company_id=$1 and status='active' and document_type in('quote','invoice')
      order by document_type
    `,[company]);
    if(activeTemplates.rows.length!==5)throw new Error(`templates: expected 2 seeded models plus 3 user models, got ${JSON.stringify(activeTemplates.rows)}`);
    if(activeTemplates.rows.filter(row=>row.is_default).length!==2)throw new Error(`templates: expected one default per document family ${JSON.stringify(activeTemplates.rows)}`);
    if(!activeTemplates.rows.some(row=>row.document_type==='quote'&&row.name==='Modèle de devis'))throw new Error('templates: unique quote model is missing');
    if(!activeTemplates.rows.some(row=>row.document_type==='invoice'&&row.name==='Modèle de facture'))throw new Error('templates: unique invoice model is missing');
    const archivedTemplates=await db.query(`
      select count(*)::int count from public.document_templates
      where company_id=$1 and status='archived' and document_type in('quote','invoice')
    `,[company]);
    if(Number(archivedTemplates.rows[0]?.count)!==0)throw new Error('templates: the bootstrap must not archive user-created models');
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    // Espace Clients : contacts multiples, rôles, adresses, préférences et
    // compte auxiliaire sont persistés par les RPC atomiques de la migration.
    const firstContact=await db.query(
      "select public.save_client_contact($1,$2::jsonb,array['primary','commercial']) result",
      [client,JSON.stringify({first_name:'Paul',last_name:'Premier',email:'paul@client.test',is_primary:true,active:true})]
    );
    const recipient=await db.query(
      "select public.save_client_contact($1,$2::jsonb,array['primary','billing','signatory']) result",
      [client,JSON.stringify({first_name:'Marie',last_name:'Destinataire',job_title:'Direction financière',email:'marie@client.test',is_primary:true,active:true})]
    );
    const recipientId=recipient.rows[0].result.id;
    const primaryContacts=await db.query('select id,is_primary from public.client_contacts where client_id=$1 order by created_at',[client]);
    if(primaryContacts.rows.filter(row=>row.is_primary).length!==1||primaryContacts.rows.find(row=>row.id===firstContact.rows[0].result.id)?.is_primary)
      throw new Error(`clients: exactly one primary contact was expected ${JSON.stringify(primaryContacts.rows)}`);
    const contactRoles=await db.query('select role from public.client_contact_roles where contact_id=$1 order by role',[recipientId]);
    if(!['billing','primary','signatory'].every(role=>contactRoles.rows.some(row=>row.role===role)))
      throw new Error(`clients: contact roles are incomplete ${JSON.stringify(contactRoles.rows)}`);
    const billingAddress=await db.query(
      'select public.save_client_address($1,$2::jsonb) result',
      [client,JSON.stringify({label:'Facturation Lyon',address_type:'billing',recipient_name:'Marie Destinataire',company_name:'Client Test',address_line_1:'25 rue Facture',postal_code:'69002',city:'Lyon',country_code:'FR',is_primary:true,is_default_billing:true,active:true})]
    );
    const serviceAddress=await db.query(
      'select public.save_client_address($1,$2::jsonb) result',
      [client,JSON.stringify({label:'Chantier Paris',address_type:'service',recipient_name:'Chef de chantier',address_line_1:'8 avenue du Test',postal_code:'75008',city:'Paris',country_code:'FR',is_default_service:true,is_default_shipping:true,active:true})]
    );
    const billingAddressId=billingAddress.rows[0].result.id,serviceAddressId=serviceAddress.rows[0].result.id;
    await db.query('select public.save_client_preferences($1,$2::jsonb) result',[client,JSON.stringify({payment_terms:'days_45',payment_delay_days:45,payment_method:'bank_transfer',currency:'EUR',language:'fr',usual_discount_rate:2.5,document_notes:'Préférence réelle du client'})]);
    const preferences=await db.query('select default_contact_id,billing_address_id,shipping_address_id,service_address_id,payment_delay_days from public.client_preferences where client_id=$1',[client]);
    if(preferences.rows[0].default_contact_id!==recipientId||preferences.rows[0].billing_address_id!==billingAddressId
      ||preferences.rows[0].shipping_address_id!==serviceAddressId||preferences.rows[0].service_address_id!==serviceAddressId
      ||Number(preferences.rows[0].payment_delay_days)!==45)
      throw new Error(`clients: partial preference save erased defaults ${JSON.stringify(preferences.rows[0])}`);
    const directory=await db.query(
      "select public.get_client_directory_v2($1,'Client',jsonb_build_object('status','active'),'name','asc',20,0) result",
      [company]
    );
    if(Number(directory.rows[0].result?.total)!==1||directory.rows[0].result?.items?.[0]?.id!==client)
      throw new Error(`clients: server-side directory filters or pagination are invalid ${JSON.stringify(directory.rows[0].result)}`);
    const automaticAccount=await db.query("select public.assign_client_auxiliary_account($1,'automatic',null,null,current_date,'Création automatique',false) result",[client]);
    if(!automaticAccount.rows[0].result.auxiliary_account)throw new Error('clients: automatic auxiliary account was not assigned');
    const manualAccount=await db.query("select public.assign_client_auxiliary_account($1,'manual','CLI-TEST',null,current_date,'Validation manuelle',false) result",[client]);
    if(manualAccount.rows[0].result.auxiliary_account!=='CLI-TEST')throw new Error('clients: manual auxiliary account was not persisted');
    const accountHistory=await db.query('select count(*)::int count from public.client_account_history where client_id=$1',[client]);
    if(Number(accountHistory.rows[0].count)!==2)throw new Error(`clients: account history is incomplete ${JSON.stringify(accountHistory.rows[0])}`);
    // Une entreprise étrangère reste invisible, même si son UUID est connu.
    const otherActor='77777777-7777-4777-8777-777777777777',otherCompany='88888888-8888-4888-8888-888888888888',otherClient='99999999-9999-4999-8999-999999999999';
    await db.exec('reset role');
    await db.query("insert into auth.users(id,email) values($1,'other@piloz.fr')",[otherActor]);
    await db.query("insert into public.companies(id,owner_user_id,name) values($1,$2,'Autre entreprise')",[otherCompany,otherActor]);
    await db.exec(`set request.jwt.claim.sub='${otherActor}';`);
    await db.query("insert into public.company_members(company_id,user_id,role) values($1,$2,'owner')",[otherCompany,otherActor]);
    await db.query("insert into public.clients(id,company_id,kind,legal_name,created_by) values($1,$2,'company','Client étranger',$3)",[otherClient,otherCompany,otherActor]);
    await db.query("insert into public.company_settings(company_id,legal_name,siret,address_line1,postal_code,city,country,email,subject_to_vat,default_vat_rate,onboarding_completed_at) values($1,'Entreprise B','98765432100019','9 rue B','33000','Bordeaux','France','b@example.test',true,20,now()) on conflict(company_id) do update set legal_name=excluded.legal_name,siret=excluded.siret,address_line1=excluded.address_line1,postal_code=excluded.postal_code,city=excluded.city",[otherCompany]);
    await db.query("update public.clients set address_line_1='10 rue Client B',postal_code='33000',city='Bordeaux',country_code='FR' where id=$1",[otherClient]);
    const foreignDraft=(await db.query('select public.save_document_draft($1,$2::jsonb,$3::jsonb) result',[null,JSON.stringify({company_id:otherCompany,document_type:'invoice',version:1,client_id:otherClient,issue_date:'2026-07-23',due_date:'2026-08-23',subject:'Facture entreprise B',currency:'EUR',language:'fr',sale_type:'services',payment_terms:'days_30',payment_method:'bank_transfer',discount_rate:0,deposit_rate:0,pipeline_stage:'draft',metadata:{pipeline_stage:'draft'}}),JSON.stringify([{id:crypto.randomUUID(),position:1,line_type:'free_item',name:'Prestation B',description:'Donnée isolée',quantity:1,unit:'unité',unit_price:100,discount_rate:0,tax_rate:20,optional:false,line_metadata:{}}])])).rows[0].result;
    const foreignInvoice=(await db.query('select public.finalize_document($1) result',[foreignDraft.id])).rows[0].result;
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    const foreignClient=await db.query('select id from public.clients where id=$1',[otherClient]);
    if(foreignClient.rows.length!==0)throw new Error('clients: RLS exposed a client from another company');
    const foreignSummary=await db.query('select public.get_client_workspace_summary($1)',[otherClient]).then(()=>null,error=>error);
    if(!foreignSummary||!/client_not_found/.test(foreignSummary.message))throw new Error('clients: workspace RPC exposed another company');
    const foreignDocument=await db.query('select id from public.documents where id=$1',[foreignInvoice.id]);
    if(foreignDocument.rows.length!==0)throw new Error('security: RLS exposed an invoice from another company');
    const foreignPayment=await db.query("select public.record_multi_invoice_payment($1::jsonb,10,'bank_transfer',now(),null,null,null,'Paiement interdit',null,'{}'::jsonb,null,false,$2::uuid)",[JSON.stringify([{document_id:foreignInvoice.id,amount:'10.00'}]),crypto.randomUUID()]).then(()=>null,error=>error);
    if(!foreignPayment||!/missing_permission:record_multi_invoice_payment/.test(foreignPayment.message))throw new Error('security: company A was able to reach the payment path of company B');
    const foreignEmail=await db.query("select public.record_manual_document_email($1,array['client@example.test'],array[]::text[],'Facture','Message','manual')",[foreignInvoice.id]).then(()=>null,error=>error);
    if(!foreignEmail||!/missing_permission:resend_invoice/.test(foreignEmail.message))throw new Error('security: company A was able to reach the email path of company B');
    // Le devis reçoit son numéro officiel et son statut "en attente" dès son
    // premier enregistrement — plus de brouillon, plus de finalisation.
    const quote=await saveDraft(db,'quote');
    await db.query('select public.save_document_client_context($1,$2,$3,$4)',[quote.id,recipientId,billingAddressId,serviceAddressId]);
    const quoteContext=await db.query('select contact_id,billing_address_id,delivery_address_id,snapshot_id from public.documents where id=$1',[quote.id]);
    if(quoteContext.rows[0].contact_id!==recipientId||quoteContext.rows[0].billing_address_id!==billingAddressId||quoteContext.rows[0].delivery_address_id!==serviceAddressId)
      throw new Error(`clients: quote context was not persisted ${JSON.stringify(quoteContext.rows[0])}`);
    const quoteSnapshotContext=await db.query('select contact_payload,address_payload from public.document_contact_snapshots c join public.document_address_snapshots a on a.snapshot_id=c.snapshot_id and a.address_kind=\'billing\' where c.snapshot_id=$1',[quoteContext.rows[0].snapshot_id]);
    if(quoteSnapshotContext.rows[0]?.contact_payload?.first_name!=='Marie'||quoteSnapshotContext.rows[0]?.address_payload?.city!=='Lyon')
      throw new Error(`clients: quote snapshot context is incomplete ${JSON.stringify(quoteSnapshotContext.rows[0])}`);
    if(quote.status!=='pending')throw new Error(`quote: expected initial status pending, got ${quote.status}`);
    const quoteRow=await db.query('select snapshot_id,finalized_at from public.documents where id=$1',[quote.id]);
    if(!quoteRow.rows[0].snapshot_id)throw new Error('quote: expected a snapshot to exist right after the first save (for PDF generation)');
    if(quoteRow.rows[0].finalized_at)throw new Error('quote: finalized_at should stay null — a quote is never content-locked before invoicing');
    // Le devis reste modifiable librement (contenu, prix...) : un second
    // enregistrement sur le même document doit réussir sans créer de version.
    const quoteEdited=await saveDraft(db,'quote',quote.id,250);
    if(quoteEdited.id!==quote.id)throw new Error('quote: editing should reuse the same document id, not create a new one');
    if(quoteEdited.total!==300)throw new Error(`quote: expected updated total 300 after edit, got ${quoteEdited.total}`);
    const quoteRowAfterEdit=await db.query('select snapshot_id from public.documents where id=$1',[quote.id]);
    if(quoteRowAfterEdit.rows[0].snapshot_id===quoteRow.rows[0].snapshot_id)throw new Error('quote: snapshot should be refreshed after an edit so the PDF reflects the new content');
    // finalize_document redevient réservé aux factures : un devis doit être refusé.
    const quoteFinalizeAttempt=await db.query('select public.finalize_document($1) result',[quote.id]).then(()=>null,error=>error);
    if(!quoteFinalizeAttempt||!/document_type_cannot_be_finalized/.test(quoteFinalizeAttempt.message))
      throw new Error(`quote: finalize_document should reject quotes again, got ${quoteFinalizeAttempt&&quoteFinalizeAttempt.message}`);
    // Tant qu'aucune facture n'en découle, le statut peut basculer vers
    // accepté ou refusé.
    const accepted=await db.query("select public.transition_document_status($1,'accepted') result",[quote.id]);
    if(accepted.rows[0].result.status!=='accepted')throw new Error(`quote: expected status accepted, got ${JSON.stringify(accepted.rows[0].result)}`);
    const rejectedBack=await db.query("select public.transition_document_status($1,'rejected') result",[quote.id]);
    if(rejectedBack.rows[0].result.status!=='rejected')throw new Error(`quote: expected status rejected, got ${JSON.stringify(rejectedBack.rows[0].result)}`);
    await db.query("select public.transition_document_status($1,'accepted') result",[quote.id]);
    // Dès qu'une facture est créée à partir du devis, celui-ci passe
    // automatiquement à "accepté" et son statut se verrouille définitivement.
    const convertedInvoiceId=await db.query('select public.convert_quote_to_invoice($1) result',[quote.id]);
    const quoteAfterConversion=await db.query('select status from public.documents where id=$1',[quote.id]);
    if(quoteAfterConversion.rows[0].status!=='accepted')throw new Error(`quote: expected accepted after conversion, got ${quoteAfterConversion.rows[0].status}`);
    const lockedAttempt=await db.query("select public.transition_document_status($1,'rejected') result",[quote.id]).then(()=>null,error=>error);
    if(!lockedAttempt||!/quote_locked_by_invoice/.test(lockedAttempt.message))
      throw new Error(`quote: transition_document_status should be locked once invoiced, got ${lockedAttempt&&lockedAttempt.message}`);
    const editAfterInvoiceAttempt=await saveDraft(db,'quote',quote.id,999).then(()=>null,error=>error);
    if(!editAfterInvoiceAttempt||!/quote_locked_by_invoice/.test(editAfterInvoiceAttempt.message))
      throw new Error(`quote: content edits should be locked once invoiced, got ${editAfterInvoiceAttempt&&editAfterInvoiceAttempt.message}`);
    // La facture brouillon n'a aucun numéro légal. La finalisation l'attribue
    // dans la même transaction que le verrouillage et l'instantané.
    const invoice=await saveDraft(db,'invoice');
    await db.query('select public.save_document_client_context($1,$2,$3,$4)',[invoice.id,recipientId,billingAddressId,serviceAddressId]);
    const final=await db.query('select public.finalize_document($1) result',[invoice.id]);
    const finalized=final.rows[0].result;
    if(!finalized?.number||invoice.number!==null||finalized.status!=='finalized'||!finalized.snapshot_id)throw new Error(`invoice: invalid final result ${JSON.stringify(finalized)}`);
    const frozenContact=await db.query('select contact_payload from public.document_contact_snapshots where snapshot_id=$1',[finalized.snapshot_id]);
    const frozenBilling=await db.query("select address_payload from public.document_address_snapshots where snapshot_id=$1 and address_kind='billing'",[finalized.snapshot_id]);
    if(frozenContact.rows[0]?.contact_payload?.first_name!=='Marie'||frozenBilling.rows[0]?.address_payload?.address_line_1!=='25 rue Facture')
      throw new Error(`clients: final invoice snapshot did not freeze the selected recipient ${JSON.stringify({frozenContact:frozenContact.rows,frozenBilling:frozenBilling.rows})}`);
    await db.query(
      "select public.save_client_contact($1,$2::jsonb,array['primary','billing','signatory']) result",
      [client,JSON.stringify({id:recipientId,first_name:'Marie modifiée',last_name:'Destinataire',email:'nouveau@client.test',is_primary:true,active:true})]
    );
    await db.query('select public.save_client_address($1,$2::jsonb) result',[client,JSON.stringify({id:billingAddressId,label:'Facturation Lyon',address_type:'billing',address_line_1:'99 rue Modifiée',postal_code:'69003',city:'Lyon',country_code:'FR',is_primary:true,is_default_billing:true,active:true})]);
    const frozenAfterEdit=await db.query('select contact_payload from public.document_contact_snapshots where snapshot_id=$1',[finalized.snapshot_id]);
    const addressAfterEdit=await db.query("select address_payload from public.document_address_snapshots where snapshot_id=$1 and address_kind='billing'",[finalized.snapshot_id]);
    if(frozenAfterEdit.rows[0]?.contact_payload?.first_name!=='Marie'||addressAfterEdit.rows[0]?.address_payload?.address_line_1!=='25 rue Facture')
      throw new Error('clients: edits to the customer record altered a finalized invoice snapshot');
    const validation=await db.query('select public.validate_invoice_for_finalization($1) result',[invoice.id]);
    if(!validation.rows[0].result?.valid)throw new Error(`invoice: central validation failed ${JSON.stringify(validation.rows[0].result)}`);
    const allocation=await db.query('select full_number,sequence_value from public.document_number_allocations where document_id=$1',[invoice.id]);
    if(allocation.rows.length!==1||allocation.rows[0].full_number!==finalized.number||Number(allocation.rows[0].sequence_value)!==1)
      throw new Error(`invoice: number allocation is not traceable ${JSON.stringify(allocation.rows)}`);
    const versioned=await db.query('select fiscal_security_status,application_version,database_schema_version,calculation_version,legal_mentions_snapshot from public.documents where id=$1',[invoice.id]);
    if(versioned.rows[0].fiscal_security_status!=='legacy_unsecured'||!versioned.rows[0].application_version||versioned.rows[0].calculation_version!=='financial-v1')
      throw new Error(`invoice: version manifest is incomplete ${JSON.stringify(versioned.rows[0])}`);
    const convertedDraftId=convertedInvoiceId.rows[0].result;
    const draftPaymentAttempt=await db.query("select public.record_document_payment_v2($1,10,'bank_transfer','DRAFT','2026-07-21T10:00:00Z',null) result",[convertedDraftId]).then(()=>null,error=>error);
    if(!draftPaymentAttempt||!/invalid_invoice_state/.test(draftPaymentAttempt.message))
      throw new Error(`payments: a draft invoice must reject payments, got ${draftPaymentAttempt&&draftPaymentAttempt.message}`);
    await db.exec('reset role');
    await db.query("update public.documents set issue_date='2026-07-20',due_date='2026-08-19' where id=$1",[convertedDraftId]);
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    const backdatedFinalization=await db.query('select public.finalize_document($1) result',[convertedDraftId]).then(()=>null,error=>error);
    if(!backdatedFinalization||!/invoice_issue_date_before_last_finalized:2026-07-21/.test(backdatedFinalization.message))
      throw new Error(`invoice: a backdated finalization must be rejected, got ${backdatedFinalization&&backdatedFinalization.message}`);
    const backdatedDraft=await db.query('select status,number,finalized_at from public.documents where id=$1',[convertedDraftId]);
    if(backdatedDraft.rows[0].status!=='draft'||backdatedDraft.rows[0].number||backdatedDraft.rows[0].finalized_at)
      throw new Error(`invoice: rejected backdated document must remain an unnumbered draft ${JSON.stringify(backdatedDraft.rows[0])}`);
    const allocationMutation=await db.query('delete from public.document_number_allocations where document_id=$1',[invoice.id]).then(()=>null,error=>error);
    if(!allocationMutation||!/(immutable_fiscal_record|permission denied)/.test(allocationMutation.message))throw new Error('invoice: number allocation must be immutable');
    const initialChain=await db.query('select public.verify_fiscal_event_chain($1) result',[company]);
    if(!initialChain.rows[0].result?.valid||Number(initialChain.rows[0].result.checked_events)<1)throw new Error(`fiscal events: finalized invoice is not chained ${JSON.stringify(initialChain.rows[0].result)}`);
    const payment=await db.query("select public.record_document_payment_v2($1,50,'bank_transfer','TEST-001','2026-07-21T12:00:00Z',null) result",[invoice.id]);
    const paymentId=payment.rows[0].result;
    const correction=await db.query("select public.cancel_document_payment($1,'Erreur de saisie') result",[paymentId]);
    const ledger=await db.query('select id,amount,entry_type,reverses_payment_id,status from public.payments where document_id=$1 order by created_at,id',[invoice.id]);
    if(ledger.rows.length!==2||Number(ledger.rows[0].amount)!==50||Number(ledger.rows[1].amount)!==-50||ledger.rows[1].reverses_payment_id!==paymentId)
      throw new Error(`payments: inverse correction is invalid ${JSON.stringify(ledger.rows)}`);
    const originalMutation=await db.query("update public.payments set reference='ALTERED' where id=$1",[paymentId]).then(()=>null,error=>error);
    if(!originalMutation||!/(payment_ledger_is_append_only|permission denied)/.test(originalMutation.message))throw new Error('payments: original entry must be immutable');
    await db.query("select public.record_document_payment_v2($1,120,'bank_transfer','TEST-002','2026-07-21T13:00:00Z',null) result",[invoice.id]);
    const paidInvoice=await db.query('select status from public.documents where id=$1',[invoice.id]);
    if(paidInvoice.rows[0].status!=='paid')throw new Error(`payments: invoice should be paid, got ${paidInvoice.rows[0].status}`);
    const receipt=await db.query("select public.record_document_receipt($1,20,'bank_transfer','TEST-OVERPAYMENT','2026-07-21T14:00:00Z','Trop-perÃ§u de test') result",[invoice.id]);
    const overpaymentId=receipt.rows[0].result?.overpayment_id;
    if(!overpaymentId||Number(receipt.rows[0].result?.overpayment_amount)!==20||Number(receipt.rows[0].result?.allocated_amount)!==0)
      throw new Error(`payments: overpayment split is invalid ${JSON.stringify(receipt.rows[0].result)}`);
    await db.query("select public.record_document_payment_reversal($1,'refund',5,'Remboursement partiel 1','2026-07-21T15:00:00Z') result",[overpaymentId]);
    await db.query("select public.record_document_payment_reversal($1,'refund',15,'Remboursement partiel 2','2026-07-21T16:00:00Z') result",[overpaymentId]);
    const overReversal=await db.query("select public.record_document_payment_reversal($1,'refund',1,'Remboursement excessif','2026-07-21T17:00:00Z') result",[overpaymentId]).then(()=>null,error=>error);
    if(!overReversal||!/(payment_already_fully_reversed|payment_reversal_exceeds_remaining_amount)/.test(overReversal.message))
      throw new Error(`payments: a fully reversed overpayment must reject another reversal ${overReversal&&overReversal.message}`);
    const overpaymentLedger=await db.query('select entry_type,amount,reverses_payment_id from public.payments where id=$1 or reverses_payment_id=$1 order by paid_at,id',[overpaymentId]);
    if(overpaymentLedger.rows.length!==3||overpaymentLedger.rows.filter(row=>row.entry_type==='refund').length!==2
      ||overpaymentLedger.rows.reduce((sum,row)=>sum+Number(row.amount),0)!==0)
      throw new Error(`payments: partial refund ledger is invalid ${JSON.stringify(overpaymentLedger.rows)}`);
    const multiDraftA=await saveDraft(db,'invoice',null,100),multiDraftB=await saveDraft(db,'invoice',null,200);
    await db.exec('reset role');
    await db.query("update public.company_document_settings set bank_name='Banque PILOZ',bank_account_holder='Société Test',iban='FR7612345678901234567890123',bic='PILOFRPP' where company_id=$1",[company]);
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    const multiInvoiceA=(await db.query('select public.finalize_document($1) result',[multiDraftA.id])).rows[0].result;
    const multiInvoiceB=(await db.query('select public.finalize_document($1) result',[multiDraftB.id])).rows[0].result;
    const multiKey='77777777-7777-4777-8777-777777777777',multiArgs=[
      JSON.stringify([{document_id:multiInvoiceA.id,amount:'60.00'},{document_id:multiInvoiceB.id,amount:'90.00'}]),
      '160.00','bank_transfer','2026-07-23T12:00:00Z','2026-07-23','MULTI-001','BANK-001','Règlement groupé','Test multi-factures',
      JSON.stringify({bank_name:'Banque Test',iban_last4:'1234'}),null,true,multiKey
    ];
    const multiPayment=await db.query('select public.record_multi_invoice_payment($1::jsonb,$2::numeric,$3,$4::timestamptz,$5::date,$6,$7,$8,$9,$10::jsonb,$11,$12::boolean,$13::uuid) result',multiArgs);
    const multiResult=multiPayment.rows[0].result;
    if(!multiResult?.payment_number?.startsWith('REG-2026-')||Number(multiResult.received_amount)!==160
      ||Number(multiResult.allocated_amount)!==150||Number(multiResult.unallocated_amount)!==10||multiResult.documents?.length!==2)
      throw new Error(`multi-payment: invalid receipt ${JSON.stringify(multiResult)}`);
    const secureReceipt=await db.query('select receiving_account,bank_reference from public.payment_receipt_read_model where id=$1',[multiResult.receipt_id]);
    if(secureReceipt.rows[0]?.receiving_account?.bank_name!=='Banque PILOZ'||secureReceipt.rows[0]?.receiving_account?.iban_last4!=='0123'||secureReceipt.rows[0]?.bank_reference!=='BANK-001')
      throw new Error(`multi-payment: receiving account was trusted from the browser or masked for its owner ${JSON.stringify(secureReceipt.rows[0])}`);
    const multiLedger=await db.query('select count(*)::int count,sum(amount)::numeric total from public.payments where payment_receipt_id=$1',[multiResult.receipt_id]);
    if(Number(multiLedger.rows[0].count)!==2||Number(multiLedger.rows[0].total)!==150)
      throw new Error(`multi-payment: invalid allocations ${JSON.stringify(multiLedger.rows[0])}`);
    const multiReplay=(await db.query('select public.record_multi_invoice_payment($1::jsonb,$2::numeric,$3,$4::timestamptz,$5::date,$6,$7,$8,$9,$10::jsonb,$11,$12::boolean,$13::uuid) result',multiArgs)).rows[0].result;
    if(multiReplay?.idempotent!==true||multiReplay?.receipt_id!==multiResult.receipt_id)
      throw new Error(`multi-payment: idempotency failed ${JSON.stringify(multiReplay)}`);
    const mismatchedArgs=[...multiArgs];mismatchedArgs[1]='161.00';
    const mismatchedReplay=await db.query('select public.record_multi_invoice_payment($1::jsonb,$2::numeric,$3,$4::timestamptz,$5::date,$6,$7,$8,$9,$10::jsonb,$11,$12::boolean,$13::uuid) result',mismatchedArgs).then(()=>null,error=>error);
    if(!mismatchedReplay||!/idempotency_payload_mismatch/.test(mismatchedReplay.message))
      throw new Error('multi-payment: an idempotency key must not accept a different payload');
    const immutableReceipt=await db.query("update public.payment_receipts set label='Altéré' where id=$1",[multiResult.receipt_id]).then(()=>null,error=>error);
    if(!immutableReceipt||!/(immutable_fiscal_record|permission denied)/.test(immutableReceipt.message))
      throw new Error('multi-payment: receipt must be append-only');
    const reversedReceipt=(await db.query("select public.reverse_payment_receipt($1,'correction','Virement saisi deux fois','2026-07-23T16:00:00Z') result",[multiResult.receipt_id])).rows[0].result;
    if(Number(reversedReceipt?.reversed_amount)!==150||reversedReceipt?.reversals?.length!==2)
      throw new Error(`multi-payment: grouped reversal is incomplete ${JSON.stringify(reversedReceipt)}`);
    const reversedLedger=await db.query("select count(*)::int count,sum(amount)::numeric total from public.payments where payment_receipt_id=$1 or reverses_payment_id in(select ledger_payment_id from public.payment_allocations where payment_receipt_id=$1)",[multiResult.receipt_id]);
    if(Number(reversedLedger.rows[0].count)!==4||Number(reversedLedger.rows[0].total)!==0)
      throw new Error(`multi-payment: grouped reversal ledger is inconsistent ${JSON.stringify(reversedLedger.rows[0])}`);
    const allocationAudit=await db.query('select count(*)::int count,sum(amount)::numeric total from public.payment_allocations where payment_receipt_id=$1',[multiResult.receipt_id]);
    if(Number(allocationAudit.rows[0].count)!==2||Number(allocationAudit.rows[0].total)!==150)
      throw new Error('multi-payment: reversal modified immutable allocations');
    const duplicateReversal=await db.query("select public.reverse_payment_receipt($1,'correction','Nouvelle correction')",[multiResult.receipt_id]).then(()=>null,error=>error);
    if(!duplicateReversal||!/payment_already_fully_reversed/.test(duplicateReversal.message))
      throw new Error('multi-payment: a fully reversed receipt must reject another grouped reversal');
    const raceDraft=await saveDraft(db,'invoice',null,50),raceInvoice=(await db.query('select public.finalize_document($1) result',[raceDraft.id])).rows[0].result,raceKey='66666666-6666-4666-8666-666666666666',raceArgs=[JSON.stringify([{document_id:raceInvoice.id,amount:'10.00'}]),'10.00','bank_transfer','2026-07-23T17:00:00Z',null,'RACE-001',null,'Paiement simultané',null,JSON.stringify({}),null,false,raceKey];
    const raceResults=await Promise.all([1,2].map(()=>db.query('select public.record_multi_invoice_payment($1::jsonb,$2::numeric,$3,$4::timestamptz,$5::date,$6,$7,$8,$9,$10::jsonb,$11,$12::boolean,$13::uuid) result',raceArgs)));
    if(raceResults.some(result=>result.rows[0].result?.receipt_id!==raceResults[0].rows[0].result?.receipt_id))throw new Error('multi-payment: concurrent idempotent calls returned different receipts');
    const raceCount=await db.query('select count(*)::int count from public.payment_receipt_read_model where id=$1',[raceResults[0].rows[0].result.receipt_id]);
    if(Number(raceCount.rows[0].count)!==1)throw new Error('multi-payment: concurrent calls created duplicate receipts');
    await db.exec('reset role');
    for(const finalizedMulti of [multiInvoiceA,multiInvoiceB,raceInvoice]){
      const pdfPath=`${company}/documents/${finalizedMulti.id}/${finalizedMulti.snapshot_id}.pdf`,pdfHash='b'.repeat(64);
      await db.query("insert into storage.objects(bucket_id,name,metadata) values('company-files',$1,'{}'::jsonb) on conflict do nothing",[pdfPath]);
      await db.query("update public.document_snapshots set pdf_storage_path=$2,pdf_sha256=$3,pdf_status='ready',pdf_generated_at=now() where id=$1",[finalizedMulti.snapshot_id,pdfPath,pdfHash]);
      await db.query("update public.documents set final_pdf_path=$2,final_pdf_sha256=$3,final_pdf_generated_at=now(),pdf_status='ready' where id=$1",[finalizedMulti.id,pdfPath,pdfHash]);
    }
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    const manualDelivery=await db.query("select public.record_manual_document_email($1,array['factures@client.test'],array['direction@client.test'],'Facture de test','Message de test','mail_app') result",[multiInvoiceA.id]);
    const manualDeliveryRow=await db.query('select delivery_mode,delivery_status,pdf_storage_path,template_key from public.document_email_deliveries where id=$1',[manualDelivery.rows[0].result]);
    if(manualDeliveryRow.rows[0]?.delivery_mode!=='mail_app'||manualDeliveryRow.rows[0]?.delivery_status!=='recorded'||!manualDeliveryRow.rows[0]?.pdf_storage_path||manualDeliveryRow.rows[0]?.template_key!=='invoice-resend-default')
      throw new Error(`email: manual delivery history is incomplete ${JSON.stringify(manualDeliveryRow.rows[0])}`);
    const deliveryCounter=await db.query('select send_count,last_sent_at from public.documents where id=$1',[multiInvoiceA.id]);
    if(Number(deliveryCounter.rows[0]?.send_count)!==1||!deliveryCounter.rows[0]?.last_sent_at)throw new Error('email: delivery counter trigger was not applied');
    const invalidRecipient=await db.query("select public.record_manual_document_email($1,array['adresse-invalide'],array[]::text[],'Facture','Message','manual')",[multiInvoiceA.id]).then(()=>null,error=>error);
    if(!invalidRecipient||!/invalid_email_recipient/.test(invalidRecipient.message))throw new Error('email: invalid recipient must be rejected');
    const closure=await db.query("select public.generate_fiscal_closure($1,'daily',date_trunc('day',now()-interval '1 day'),date_trunc('day',now())) result",[company]);
    const closureRow=await db.query('select integrity_status,signature,closure_hash from public.fiscal_closures where id=$1',[closure.rows[0].result]);
    if(closureRow.rows[0].integrity_status!=='unsigned'||closureRow.rows[0].signature!==null||!closureRow.rows[0].closure_hash)
      throw new Error(`closure: unsigned state must remain explicit ${JSON.stringify(closureRow.rows[0])}`);
    const finalChain=await db.query('select public.verify_fiscal_event_chain($1) result',[company]);
    if(!finalChain.rows[0].result?.valid||Number(finalChain.rows[0].result.checked_events)<5)throw new Error(`fiscal events: chain verification failed ${JSON.stringify(finalChain.rows[0].result)}`);
    // Une archive stricte ne peut référencer un PDF final absent. Le test
    // simule ici l'achèvement du job par le rôle serveur, puis contrôle le
    // manifeste, son empreinte, son immutabilité et la trace d'export.
    await db.exec('reset role');
    await db.query(`update public.document_snapshots set pdf_status='ready',pdf_storage_path=$2,pdf_sha256=$3,pdf_generated_at=now() where id=$1`,
      [finalized.snapshot_id,`${company}/documents/${invoice.id}/${finalized.snapshot_id}.pdf`,'a'.repeat(64)]);
    await db.exec(`set request.jwt.claim.sub='${actor}'; set role authenticated;`);
    const archive=await db.query("select public.create_fiscal_archive($1,date_trunc('day',clock_timestamp()),clock_timestamp(),false) result",[company]);
    const archiveId=archive.rows[0].result;
    const archiveControl=await db.query('select public.verify_fiscal_archive_record($1) result',[archiveId]);
    if(!archiveControl.rows[0].result?.valid||archiveControl.rows[0].result.signature_status!=='not_configured')
      throw new Error(`archive: integrity control failed ${JSON.stringify(archiveControl.rows[0].result)}`);
    const archiveItems=await db.query('select category,content_status,content_hash from public.fiscal_archive_items where archive_id=$1 order by relative_path',[archiveId]);
    if(archiveItems.rows.length<2||!archiveItems.rows.some(row=>row.category==='structured_data'&&row.content_status==='embedded')
      ||!archiveItems.rows.some(row=>row.category==='pdf'&&row.content_status==='storage_reference'))
      throw new Error(`archive: manifest items are incomplete ${JSON.stringify(archiveItems.rows)}`);
    const archiveMutation=await db.query("update public.fiscal_archives set integrity_status='signed' where id=$1",[archiveId]).then(()=>null,error=>error);
    if(!archiveMutation||!/(immutable_fiscal_record|permission denied)/.test(archiveMutation.message))throw new Error('archive: frozen record must be immutable');
    const archiveExport=await db.query("select public.register_fiscal_archive_export($1,'json_bundle',null,'unsigned') result",[archiveId]);
    if(!archiveExport.rows[0].result)throw new Error('archive: export event was not recorded');
    const canonical=await db.query('select public.create_canonical_invoice_record($1) result',[invoice.id]);
    if(canonical.rows[0].result?.status!=='valid'||!canonical.rows[0].result?.canonical_hash)
      throw new Error(`electronic invoice: canonical model is invalid ${JSON.stringify(canonical.rows[0].result)}`);
    const canonicalRecord=await db.query('select canonical_payload,validation_status from public.electronic_invoice_records where id=$1',[canonical.rows[0].result.record_id]);
    if(canonicalRecord.rows[0].validation_status!=='valid'||canonicalRecord.rows[0].canonical_payload?.format!=='piloz-canonical-invoice'
      ||canonicalRecord.rows[0].canonical_payload?.lines?.length!==1)
      throw new Error(`electronic invoice: canonical payload is incomplete ${JSON.stringify(canonicalRecord.rows[0])}`);
    const blockedProfile=await db.query("select public.check_electronic_format_profile('ubl',null) result");
    if(blockedProfile.rows[0].result?.ready!==false||blockedProfile.rows[0].result?.code!=='official_profile_not_configured')
      throw new Error(`electronic invoice: approximate UBL generation was not blocked ${JSON.stringify(blockedProfile.rows[0].result)}`);
    const sandbox=await db.query('select public.create_platform_sandbox($1) result',[company]);
    if(!sandbox.rows[0].result)throw new Error('platform: sandbox connector was not created');
    const simulation=await db.query("select public.run_platform_sandbox_simulation($1,'send_invoice','test-idempotency-1') result",[canonical.rows[0].result.record_id]);
    const simulationReplay=await db.query("select public.run_platform_sandbox_simulation($1,'send_invoice','test-idempotency-1') result",[canonical.rows[0].result.record_id]);
    if(simulation.rows[0].result?.display_status!=='Simulation'||simulation.rows[0].result?.sent_to_administration!==false
      ||simulationReplay.rows[0].result?.idempotent!==true||simulationReplay.rows[0].result?.transmission_id!==simulation.rows[0].result?.transmission_id)
      throw new Error(`platform: sandbox is not explicit or idempotent ${JSON.stringify({simulation:simulation.rows[0].result,replay:simulationReplay.rows[0].result})}`);
    const electronicStatusAfterSimulation=await db.query('select electronic_invoice_status from public.documents where id=$1',[invoice.id]);
    if(electronicStatusAfterSimulation.rows[0].electronic_invoice_status==='transmitted')throw new Error('platform: a simulation must never mark the invoice as transmitted');
    const reporting=await db.query("select public.classify_transaction_for_french_einvoicing($1,'transaction',null) result",[invoice.id]);
    if(reporting.rows[0].result?.classification!=='e_invoice'||reporting.rows[0].result?.external_validation_required!==true
      ||reporting.rows[0].result?.transmitted!==false)
      throw new Error(`reporting: preliminary classification is invalid ${JSON.stringify(reporting.rows[0].result)}`);
    // Phase 8: least privilege, honest activation and append-only controls.
    const limitedUser='66666666-6666-4666-8666-666666666666';
    await db.exec('reset role');
    await db.query(`insert into auth.users(id,email) values($1,'readonly@piloz.fr')`,[limitedUser]);
    await db.exec(`set request.jwt.claim.sub='${actor}';`);
    await db.query("insert into public.company_members(company_id,user_id,role) values($1,$2,'read_only')",[company,limitedUser]);
    await db.exec('set role authenticated;');
    const permissionEvent=await db.query("select count(*)::int count from public.fiscal_events where company_id=$1 and event_type='user_permission_changed'",[company]);
    if(Number(permissionEvent.rows[0]?.count)<1)throw new Error('roles: permission change was not written to the fiscal journal');
    await db.exec(`set request.jwt.claim.sub='${limitedUser}';`);
    const limitedPermissions=await db.query("select public.has_company_permission($1,'application_read') can_read,public.has_company_permission($1,'finalize_invoice') can_finalize",[company]);
    if(!limitedPermissions.rows[0].can_read||limitedPermissions.rows[0].can_finalize)throw new Error(`roles: read-only permissions are invalid ${JSON.stringify(limitedPermissions.rows[0])}`);
    const maskedReceipt=await db.query('select bank_reference,receiving_account,proof_storage_path from public.payment_receipt_read_model where id=$1',[multiResult.receipt_id]);
    if(maskedReceipt.rows[0]?.bank_reference!==null||Object.keys(maskedReceipt.rows[0]?.receiving_account||{}).length||maskedReceipt.rows[0]?.proof_storage_path!==null)
      throw new Error(`roles: sensitive payment fields were exposed to read-only ${JSON.stringify(maskedReceipt.rows[0])}`);
    const limitedPayment=await db.query("select public.record_multi_invoice_payment($1::jsonb,1,'bank_transfer',now(),null,null,null,'Interdit',null,'{}'::jsonb,null,false,$2::uuid)",[JSON.stringify([{document_id:raceInvoice.id,amount:'1.00'}]),crypto.randomUUID()]).then(()=>null,error=>error);
    if(!limitedPayment||!/missing_permission:record_multi_invoice_payment/.test(limitedPayment.message))throw new Error('roles: read-only user was able to record a payment');
    const limitedEmail=await db.query("select public.record_manual_document_email($1,array['client@example.test'],array[]::text[],'Facture','Message','manual')",[multiInvoiceA.id]).then(()=>null,error=>error);
    if(!limitedEmail||!/missing_permission:resend_invoice/.test(limitedEmail.message))throw new Error('roles: read-only user was able to record an invoice email');
    await db.query("update public.clients set trade_name='Interdit' where id=$1",[client]).catch(()=>null);
    const clientAfterForbiddenUpdate=await db.query('select trade_name from public.clients where id=$1',[client]);
    if(clientAfterForbiddenUpdate.rows[0]?.trade_name==='Interdit')
      throw new Error('clients: read-only user was able to update a customer');
    const forbiddenContactUpdate=await db.query(
      "select public.save_client_contact($1,$2::jsonb,array['primary'])",
      [client,JSON.stringify({id:recipientId,first_name:'Marie',last_name:'Interdit',is_primary:true,active:true})]
    ).then(()=>null,error=>error);
    if(!forbiddenContactUpdate||!/forbidden/.test(forbiddenContactUpdate.message))
      throw new Error('clients: read-only user was able to update a contact through the RPC');
    const forbiddenSummary=await db.query('select public.get_company_compliance_summary($1)',[company]).then(()=>null,error=>error);
    if(!forbiddenSummary||!/forbidden/.test(forbiddenSummary.message))throw new Error('roles: read-only user must not access the compliance dashboard');
    await db.exec(`set request.jwt.claim.sub='${actor}';`);
    const ownerMutation=await db.query("update public.company_members set role='admin' where company_id=$1 and user_id=$2",[company,actor]).then(()=>null,error=>error);
    if(!ownerMutation||!/(owner_role_requires_dedicated_transfer|permission denied)/.test(ownerMutation.message))throw new Error('roles: owner role must not be changed through generic CRUD');
    const ownerRpcMutation=await db.query("select public.set_company_member_access($1,$2,'admin','{}'::jsonb)",[company,actor]).then(()=>null,error=>error);
    if(!ownerRpcMutation||!/owner_role_requires_dedicated_transfer/.test(ownerRpcMutation.message))throw new Error('roles: controlled RPC must protect the owner role');
    const activation=await db.query("select public.evaluate_fiscal_activation($1,'production') result",[company]);
    if(activation.rows[0].result?.ready!==false||!activation.rows[0].result?.blockers?.some(item=>/KMS|preuve|profil/i.test(item)))
      throw new Error(`activation: production should remain blocked without external evidence ${JSON.stringify(activation.rows[0].result)}`);
    const productionAttempt=await db.query("select public.activate_fiscal_engine($1,'production')",[company]).then(()=>null,error=>error);
    if(!productionAttempt||!/fiscal_activation_prerequisites_missing/.test(productionAttempt.message))throw new Error('activation: production was not blocked');
    const integrity=await db.query('select public.run_company_integrity_check($1) result',[company]);
    if(integrity.rows[0].result?.status!=='valid')throw new Error(`integrity: expected valid result ${JSON.stringify(integrity.rows[0].result)}`);
    const automation=await db.query("select public.configure_fiscal_automation($1,'Europe/Paris',true,true,true,false) result",[company]);
    if(!automation.rows[0].result?.daily_closure_enabled||automation.rows[0].result?.archive_enabled)
      throw new Error(`maintenance: safe automation configuration is invalid ${JSON.stringify(automation.rows[0].result)}`);
    const maintenancePreview=await db.query('select public.preview_fiscal_maintenance($1,now()) result',[company]);
    if(maintenancePreview.rows[0].result?.automatic_archives_enabled!==false
      ||!Array.isArray(maintenancePreview.rows[0].result?.candidates))
      throw new Error(`maintenance: preview is incomplete ${JSON.stringify(maintenancePreview.rows[0].result)}`);
    const maintenanceDryRun=await db.query("select public.run_company_fiscal_maintenance($1,now(),true,'manual') result",[company]);
    if(maintenanceDryRun.rows[0].result?.dry_run!==true||maintenanceDryRun.rows[0].result?.archives_created!==0)
      throw new Error(`maintenance: dry-run must not create records ${JSON.stringify(maintenanceDryRun.rows[0].result)}`);
    const integrityEvidence=await db.query('select status,report_sha256 from public.compliance_integrity_checks where company_id=$1',[company]);
    if(integrityEvidence.rows.length!==1||integrityEvidence.rows[0].status!=='valid'||!integrityEvidence.rows[0].report_sha256)
      throw new Error(`integrity: immutable evidence is missing ${JSON.stringify(integrityEvidence.rows)}`);
    const directCertificate=await db.query("insert into public.company_software_certifications(company_id,certification_type,certificate_number,certification_body,issued_at,application_version_from) values($1,'NF 525','FAKE','Test','2026-07-22','0.0.0')",[company]).then(()=>null,error=>error);
    if(!directCertificate||!/permission denied/.test(directCertificate.message))throw new Error('certifications: browser must not create a certification directly');
    const certificationCount=await db.query('select count(*)::int count from public.company_software_certifications where company_id=$1',[company]);
    if(Number(certificationCount.rows[0]?.count)!==0)throw new Error('certifications: registry must remain empty by default');
    const rightsRequest=await db.query("select public.create_data_subject_request($1,'access','client',$2,now(),'{}'::jsonb) result",[company,client]);
    if(!rightsRequest.rows[0].result)throw new Error('privacy: data subject request was not recorded');
    const rightsRequestId=rightsRequest.rows[0].result;
    const prematureExport=await db.query('select public.generate_data_subject_export($1) result',[rightsRequestId]).then(()=>null,error=>error);
    if(!prematureExport||!/data_subject_identity_verification_required/.test(prematureExport.message))
      throw new Error('privacy: export must be blocked before identity verification');
    await db.query("select public.transition_data_subject_request($1,'in_progress','Identité contrôlée',null,null,now()) result",[rightsRequestId]);
    const subjectExport=await db.query('select public.generate_data_subject_export($1) result',[rightsRequestId]);
    if(!subjectExport.rows[0].result?.payload_sha256||Number(subjectExport.rows[0].result?.record_count)<2
      ||subjectExport.rows[0].result?.payload?.data?.subject?.id!==client)
      throw new Error(`privacy: access export is incomplete ${JSON.stringify(subjectExport.rows[0].result)}`);
    const privacyDecision=await db.query("select public.record_data_subject_request_decision($1,'customer_record','export','IdentitÃ© contrÃ´lÃ©e et donnÃ©es exportÃ©es','client',$2,false) result",[rightsRequestId,client]);
    if(!privacyDecision.rows[0].result)throw new Error('privacy: request decision was not recorded');
    const closedRightsRequest=await db.query("select public.transition_data_subject_request($1,'fulfilled','RÃ©ponse remise',null,'Export JSON remis aprÃ¨s contrÃ´le d''identitÃ©',null) result",[rightsRequestId]);
    if(closedRightsRequest.rows[0].result?.status!=='fulfilled')throw new Error('privacy: request was not fulfilled');
    await db.query("select public.set_company_retention_rule($1,'prospects',36,'last_activity','IntÃ©rÃªt lÃ©gitime Ã  valider','review',null,null) result",[company]);
    const retentionPreview=await db.query('select public.preview_company_retention_actions($1,now()) result',[company]);
    if(retentionPreview.rows[0].result?.destructive_action_executed!==false
      ||retentionPreview.rows[0].result?.rules?.[0]?.automatic_action_allowed!==false)
      throw new Error(`privacy: retention preview must remain non-destructive ${JSON.stringify(retentionPreview.rows[0].result)}`);
    const complianceSummary=await db.query('select public.get_company_compliance_summary($1) result',[company]);
    if(Number(complianceSummary.rows[0].result?.open_data_subject_requests)!==0||complianceSummary.rows[0].result?.certifications?.length!==0)
      throw new Error(`compliance summary: dishonest or incomplete result ${JSON.stringify(complianceSummary.rows[0].result)}`);
    await db.exec(fs.readFileSync(path.join(repoRoot,'supabase','tests','202607220045_privacy_roles_and_compliance_checks.sql'),'utf8'));
    await db.exec(fs.readFileSync(path.join(repoRoot,'supabase','tests','202607220047_payment_privacy_maintenance_checks.sql'),'utf8'));
    console.log(JSON.stringify({ok:true,quote:{...quote,convertedInvoiceId:convertedInvoiceId.rows[0].result},invoice:{id:invoice.id,draftNumber:invoice.number,number:finalized.number,total:invoice.total,status:finalized.status,finalizedAt:finalized.finalized_at}}));
  }finally{
    await db.close();
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
