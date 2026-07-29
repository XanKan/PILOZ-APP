const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');

const source=fs.readFileSync('assets/js/modules/onboarding/professional-onboarding.js','utf8');
const node={innerHTML:'',className:'',querySelector:()=>({focus(){}})};
const calls={settings:[],requests:[],queries:[],inserts:[]};
const context={
  console,
  encodeURIComponent,
  setTimeout,
  clearTimeout,
  requestAnimationFrame(callback){callback();},
  esc(value){return String(value??'').replace(/[&<>"']/g,character=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));},
  document:{getElementById(){return node;},createElement(){return node;},body:{appendChild(){}}},
  phase1SetupStep:1,
  phase1EnsureState(){},
  phase1CloseSetup(){},
  phase1SetEntreprise(path,value){const parts=path.split('.');let target=context.PilozRuntime.state.entreprise;while(parts.length>1)target=target[parts.shift()];target[parts[0]]=value;if(path==='fiscality.subjectToVat'&&value===false)Object.assign(context.PilozRuntime.state.entreprise.fiscality,{vatNumber:'',vatRegime:'',defaultVatRate:0});},
  phase1SetEntrepriseChoice(path,raw){context.phase1SetEntreprise(path,raw===''?null:raw==='true'?true:raw==='false'?false:raw);},
  phase1BooleanOptions(){return '<option value="true">Oui</option>';},
  sauver(){},
  toast(){},
  PilozApp:{refresh(){}},
  PilozCalculations:{validSiren(){return true;},e164(){return '+33123456789';}},
  PilozRuntime:{session:{user_id:'00000000-0000-0000-0000-000000000001'},state:{entreprise:{
    identity:{legalName:'Société Test',tradeName:'Test',legalForm:'SAS',siren:'732829320',siret:'73282932000074',apeCode:'6201Z',activity:'Logiciel',creationDate:'2026-01-01',country:'France'},
    fiscality:{subjectToVat:true,defaultVatRate:20,currency:'EUR',language:'fr'},
    documents:{quotePrefix:'DEV',quoteNextNumber:1,invoicePrefix:'FAC',invoiceNextNumber:1,creditPrefix:'AV',creditNextNumber:1,orderPrefix:'CMD',quoteValidityDays:30,defaultPaymentTerms:'À réception',defaultPaymentMethod:'Virement bancaire'},
    banking:{},setup:{lastStep:1,electronicInvoicingDeferred:true},
  }}},
  PilozERP:{
    async companyContext(){return '00000000-0000-0000-0000-000000000002';},
    async upsertCompanySettings(companyId,payload){calls.settings.push({companyId,payload});return[payload];},
    async request(...args){calls.requests.push(args);return null;},
    async query(...args){calls.queries.push(args);if(args[0]==='vat_rates')return[{id:'vat-20',rate:20,label:'Taux normal · 20 %',is_default:true,active:true}];if(args[0]==='company_logos')return[];throw new Error('L’étape 1 ne doit pas lire les adresses.');},
    async insert(...args){calls.inserts.push(args);throw new Error('L’étape 1 ne doit pas insérer une adresse.');},
    async update(){throw new Error('L’étape 1 ne doit pas modifier une adresse.');},
    async invoke(){return{};},
  },
};
context.window=context;
vm.createContext(context);
vm.runInContext(source,context,{filename:'professional-onboarding.js'});

(async()=>{
  await context.phase1SetupNext();
  assert.equal(calls.settings.length,1);
  assert.equal(calls.requests.length,1);
  assert.match(calls.requests[0][0],/\/rest\/v1\/companies\?id=eq\./);
  assert.equal(JSON.parse(calls.requests[0][1].body).name,'Test');
  assert.equal(calls.queries.length,0);
  assert.equal(calls.inserts.length,0);
  assert.equal(calls.settings[0].payload.legal_name,'Société Test');
  assert.equal(calls.settings[0].payload.siret,'73282932000074');
  assert.equal(Object.hasOwn(calls.settings[0].payload,'onboarding_completed_at'),false);
  assert.equal(context.phase1SetupStep,2);

  context.phase1SetupStep=1;
  context.PilozCalculations.validSiren=()=>false;
  await context.phase1SetupNext();
  assert.equal(calls.settings.length,1);
  assert.match(node.innerHTML,/Le SIRET saisi est invalide/);
  assert.match(node.innerHTML,/role="alert"/);

  context.phase1SetupStep=4;
  context.PilozCalculations.validSiren=()=>true;
  Object.assign(context.PilozRuntime.state.entreprise.fiscality,{subjectToVat:false,vatNumber:'FR12345678901',vatRegime:'Réel normal',defaultVatRate:20});
  await context.phase1SetupNext();
  const fiscalPayload=calls.settings.at(-1).payload;
  assert.equal(fiscalPayload.subject_to_vat,false);
  assert.equal(fiscalPayload.vat_number,null);
  assert.equal(fiscalPayload.vat_regime,null);
  assert.equal(fiscalPayload.default_vat_rate,0);

  context.phase1SetupStep=4;
  context.professionalSetVatSubject('true');
  assert.equal(context.PilozRuntime.state.entreprise.fiscality.defaultVatRate,20);
  assert.match(node.innerHTML,/data-onboarding-path="fiscality.defaultVatRate"/);
  assert.doesNotMatch(node.innerHTML,/Taux de TVA par défaut<\/label><input/);
  context.professionalSetVatSubject('false');
  assert.equal(context.PilozRuntime.state.entreprise.fiscality.defaultVatRate,0);
  assert.equal(context.PilozRuntime.state.entreprise.fiscality.vatRegime,'');
  assert.doesNotMatch(node.innerHTML,/N° TVA intracommunautaire/);
  assert.match(node.innerHTML,/automatiquement fixé à 0 %/);

  context.phase1SetupStep=5;
  context.PilozERP.upload=async()=>({});
  context.PilozERP.insert=async(...args)=>{calls.inserts.push(args);return[args[1]];};
  context.PilozERP.signedUrl=async()=>({signedURL:'https://example.test/logo-clair.png'});
  await context.professionalUploadLogo({type:'image/png',size:1024,name:'logo-clair.png'},'light');
  assert.equal(context.PilozRuntime.state.entreprise.identity.logoDeferred,false);
  assert.match(node.innerHTML,/src="https:\/\/example\.test\/logo-clair\.png"/);
  assert.match(node.innerHTML,/logo-clair\.png · Cliquer pour remplacer/);
  console.log('PASS onboarding step 1 runtime');
})().catch(error=>{console.error(error);process.exit(1);});
