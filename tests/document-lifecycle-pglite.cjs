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
    insert into public.company_settings(company_id,legal_name,siret,address_line1,postal_code,city,country,email,subject_to_vat,default_vat_rate,onboarding_completed_at)
      values('${company}','Société Test','12345678900012','1 rue du Test','75001','Paris','France','contact@piloz.fr',true,20,now())
      on conflict(company_id) do update set legal_name=excluded.legal_name;
    insert into public.company_document_settings(company_id,quote_prefix,invoice_prefix,credit_prefix,default_payment_terms,default_payment_method,quote_validity_days)
      values('${company}','DEV','FAC','AV','days_30','bank_transfer',30)
      on conflict(company_id) do nothing;
    insert into public.clients(id,company_id,kind,legal_name,email,address_line_1,postal_code,city,country_code,created_by)
      values('${client}','${company}','company','Client Test','client@piloz.fr','2 rue Client','69001','Lyon','FR','${actor}');
    set request.jwt.claim.sub='${actor}';
    set role authenticated;
  `);
}

async function saveDraft(db,type,existingId=null,unitPrice=100){
  const targetDocument={
    company_id:company,document_type:type,version:1,client_id:client,issue_date:'2026-07-21',
    due_date:type==='quote'?null:'2026-08-20',validity_date:type==='quote'?'2026-08-20':null,
    subject:type==='quote'?'Devis de test':'Facture de test',currency:'EUR',language:'fr',
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
    if(activeTemplates.rows.length!==2)throw new Error(`templates: expected exactly 2 active models, got ${JSON.stringify(activeTemplates.rows)}`);
    if(!activeTemplates.rows.every(row=>row.is_default))throw new Error(`templates: both active models must be defaults ${JSON.stringify(activeTemplates.rows)}`);
    if(!activeTemplates.rows.some(row=>row.document_type==='quote'&&row.name==='Modèle de devis'))throw new Error('templates: unique quote model is missing');
    if(!activeTemplates.rows.some(row=>row.document_type==='invoice'&&row.name==='Modèle de facture'))throw new Error('templates: unique invoice model is missing');
    const archivedTemplates=await db.query(`
      select count(*)::int count from public.document_templates
      where company_id=$1 and status='archived' and document_type in('quote','invoice')
    `,[company]);
    if(Number(archivedTemplates.rows[0]?.count)!==3)throw new Error('templates: previous models must be archived, not deleted');
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
    console.log(JSON.stringify({ok:true,quote:{...quote,convertedInvoiceId:convertedInvoiceId.rows[0].result},invoice:{id:invoice.id,draftNumber:invoice.number,number:finalized.number,total:invoice.total,status:finalized.status,finalizedAt:finalized.finalized_at}}));
  }finally{
    await db.close();
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
