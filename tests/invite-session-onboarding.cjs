const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

const index=fs.readFileSync('index.html','utf8');
const apiSource=fs.readFileSync('assets/js/api/erp-api.js','utf8');
const helperStart=index.indexOf('function isValidUuid(value)');
const helperEnd=index.indexOf('window.PilozSessionIdentityFromToken=sessionIdentityFromToken;')+'window.PilozSessionIdentityFromToken=sessionIdentityFromToken;'.length;
assert(helperStart>0&&helperEnd>helperStart,'Les helpers de session doivent rester présents dans index.html.');

const helperContext={window:{},atob,decodeURIComponent};
vm.createContext(helperContext);
vm.runInContext(index.slice(helperStart,helperEnd),helperContext);
const userId='1586bdf5-b4bb-46ed-a5f1-cdfffd330fa9';
const payload=Buffer.from(JSON.stringify({sub:userId,email:'invite@example.test'})).toString('base64url');
const token=`header.${payload}.signature`;
assert.deepEqual(JSON.parse(JSON.stringify(helperContext.window.PilozSessionIdentityFromToken(token))),{user_id:userId,email:'invite@example.test'});

const calls=[];
const storage=new Map();
const context={
  window:{
    PilozSessionIdentityFromToken:helperContext.window.PilozSessionIdentityFromToken,
    PilozRuntime:{
      config:{url:'https://example.supabase.co',key:'anon'},
      session:{access_token:token,refresh_token:'refresh'},
      async request(path){
        calls.push(path);
        const body=path.includes('list_my_pending_company_invitations')?[]:[{company_id:'00000000-0000-4000-8000-000000000001'}];
        return new Response(JSON.stringify(body),{status:200,headers:{'content-type':'application/json'}});
      }
    },
    confirm(){return false;}
  },
  localStorage:{setItem(key,value){storage.set(key,value);}},
  console,Response,fetch,Blob,URL,JSON,encodeURIComponent,decodeURIComponent,setTimeout,clearTimeout
};
context.window.window=context.window;
vm.createContext(context);
vm.runInContext(apiSource,context,{filename:'erp-api.js'});

(async()=>{
  const companyId=await context.window.PilozERP.companyContext();
  assert.equal(companyId,'00000000-0000-4000-8000-000000000001');
  assert.equal(context.window.PilozRuntime.session.user_id,userId,'Le sub du JWT doit hydrater la session invitée.');
  const preferenceCall=calls.find(path=>path.includes('/user_preferences?'));
  assert(preferenceCall.includes(`user_id=eq.${userId}`),'La requête doit contenir un UUID valide.');
  assert(!preferenceCall.includes('user_id=eq.&'),'Un filtre UUID vide ne doit jamais être envoyé.');
  const legacyStart=index.indexOf('let legacyCloudStateAvailable=true;');
  const legacyEnd=index.indexOf('async function deconnecter()',legacyStart);
  let legacyRequests=0;
  const legacyContext={
    Response,
    async sb(){legacyRequests+=1;return new Response(JSON.stringify({code:'PGRST205',message:"Could not find the table 'public.etat' in the schema cache"}),{status:404,headers:{'content-type':'application/json'}});},
    JSON,Date
  };
  vm.createContext(legacyContext);
  vm.runInContext(index.slice(legacyStart,legacyEnd),legacyContext);
  assert.equal(await vm.runInContext('cloudCharger()',legacyContext),null,'La table historique absente ne doit pas faire échouer la connexion.');
  assert.equal(await vm.runInContext('cloudCharger()',legacyContext),null);
  assert.equal(legacyRequests,1,'Le stockage historique absent ne doit pas être interrogé en boucle.');
  console.log('PASS invite session onboarding');
})().catch(error=>{console.error(error);process.exitCode=1;});
