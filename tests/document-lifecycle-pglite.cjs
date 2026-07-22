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
    insert into auth.users(id,email,raw_user_meta_data) values('${actor}','test@piloz.fr',jsonb_build_object('first_name','Quentin'));
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
    id:type==='quote'?'44444444-4444-4444-8444-444444444444':'55555555-5555-4555-8555-555555555555',
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
    // Le devis reçoit son numéro officiel et son statut "en attente" dès son
    // premier enregistrement — plus de brouillon, plus de finalisation.
    const quote=await saveDraft(db,'quote');
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
    const final=await db.query('select public.finalize_document($1) result',[invoice.id]);
    const finalized=final.rows[0].result;
    if(!finalized?.number||invoice.number!==null||finalized.status!=='finalized'||!finalized.snapshot_id)throw new Error(`invoice: invalid final result ${JSON.stringify(finalized)}`);
    const validation=await db.query('select public.validate_invoice_for_finalization($1) result',[invoice.id]);
    if(!validation.rows[0].result?.valid)throw new Error(`invoice: central validation failed ${JSON.stringify(validation.rows[0].result)}`);
    const allocation=await db.query('select full_number,sequence_value from public.document_number_allocations where document_id=$1',[invoice.id]);
    if(allocation.rows.length!==1||allocation.rows[0].full_number!==finalized.number||Number(allocation.rows[0].sequence_value)!==1)
      throw new Error(`invoice: number allocation is not traceable ${JSON.stringify(allocation.rows)}`);
    const versioned=await db.query('select fiscal_security_status,application_version,database_schema_version,calculation_version,legal_mentions_snapshot from public.documents where id=$1',[invoice.id]);
    if(versioned.rows[0].fiscal_security_status!=='legacy_unsecured'||!versioned.rows[0].application_version||versioned.rows[0].calculation_version!=='financial-v1')
      throw new Error(`invoice: version manifest is incomplete ${JSON.stringify(versioned.rows[0])}`);
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
    if(archiveItems.rows.length!==2||!archiveItems.rows.some(row=>row.category==='structured_data'&&row.content_status==='embedded')
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
    const integrityEvidence=await db.query('select status,report_sha256 from public.compliance_integrity_checks where company_id=$1',[company]);
    if(integrityEvidence.rows.length!==1||integrityEvidence.rows[0].status!=='valid'||!integrityEvidence.rows[0].report_sha256)
      throw new Error(`integrity: immutable evidence is missing ${JSON.stringify(integrityEvidence.rows)}`);
    const directCertificate=await db.query("insert into public.company_software_certifications(company_id,certification_type,certificate_number,certification_body,issued_at,application_version_from) values($1,'NF 525','FAKE','Test','2026-07-22','0.0.0')",[company]).then(()=>null,error=>error);
    if(!directCertificate||!/permission denied/.test(directCertificate.message))throw new Error('certifications: browser must not create a certification directly');
    const certificationCount=await db.query('select count(*)::int count from public.company_software_certifications where company_id=$1',[company]);
    if(Number(certificationCount.rows[0]?.count)!==0)throw new Error('certifications: registry must remain empty by default');
    const rightsRequest=await db.query("select public.create_data_subject_request($1,'access','client','CLIENT-TEST',now(),'{}'::jsonb) result",[company]);
    if(!rightsRequest.rows[0].result)throw new Error('privacy: data subject request was not recorded');
    const complianceSummary=await db.query('select public.get_company_compliance_summary($1) result',[company]);
    if(Number(complianceSummary.rows[0].result?.open_data_subject_requests)!==1||complianceSummary.rows[0].result?.certifications?.length!==0)
      throw new Error(`compliance summary: dishonest or incomplete result ${JSON.stringify(complianceSummary.rows[0].result)}`);
    await db.exec(fs.readFileSync(path.join(repoRoot,'supabase','tests','202607220045_privacy_roles_and_compliance_checks.sql'),'utf8'));
    console.log(JSON.stringify({ok:true,quote:{...quote,convertedInvoiceId:convertedInvoiceId.rows[0].result},invoice:{id:invoice.id,draftNumber:invoice.number,number:finalized.number,total:invoice.total,status:finalized.status,finalizedAt:finalized.finalized_at}}));
  }finally{
    await db.close();
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
