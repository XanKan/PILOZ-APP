(function(global){
  const JSON_TYPES=['application/json','application/problem+json','application/vnd.pgrst.object+json'];
  function responseMeta(response,path){return{path:String(path||''),status:Number(response?.status)||0,contentType:response?.headers?.get?.('content-type')||'',requestId:response?.headers?.get?.('x-request-id')||response?.headers?.get?.('sb-request-id')||''};}
  function technicalLog(message,response,path,error){
    const meta=responseMeta(response,path);
    console.error('[PILOZ API] '+message,meta,error instanceof Error?{name:error.name,message:error.message}:undefined);
  }
  function isJsonContentType(value){const type=String(value||'').split(';')[0].trim().toLowerCase();return JSON_TYPES.includes(type)||type.endsWith('+json');}
  async function readBody(response,path){
    if(!response||response.status===204||response.status===205)return null;
    const contentLength=response.headers?.get?.('content-length');
    if(contentLength==='0')return null;
    let text='';
    try{text=await response.text();}catch(error){technicalLog('Lecture de réponse impossible',response,path,error);throw new Error('La réponse du serveur n’a pas pu être lue.');}
    if(!text.trim())return null;
    const contentType=response.headers?.get?.('content-type')||'';
    if(!isJsonContentType(contentType))return{text,contentType};
    try{return JSON.parse(text);}catch(error){technicalLog('JSON de réponse invalide',response,path,error);const failure=new Error('La réponse du serveur est invalide. Réessayez dans quelques instants.');failure.status=response.status;failure.code='invalid_json_response';throw failure;}
  }
  function serializeBody(value){
    try{return JSON.stringify(value,(key,item)=>item===undefined?null:item);}
    catch(error){console.error('[PILOZ API] Sérialisation de la requête impossible',{name:error.name,message:error.message});const failure=new Error('Certaines informations du formulaire ne peuvent pas être enregistrées.');failure.code='invalid_request_body';throw failure;}
  }
  const FISCAL_DOCUMENT_TYPES=new Set(['invoice','deposit_invoice','balance_invoice','credit_note','proforma_invoice']);
  const FISCAL_DOCUMENT_FIELDS=new Set(['document_type','number','client_id','status','issue_date','due_date','currency','payment_terms','payment_method','discount_rate','total_cost','total_excl_tax','total_tax','total_incl_tax','source_document_id','validated_at','finalized_at','finalized_by','locked_at','snapshot_id','fiscal_security_status']);
  function parsedRequestBody(body){if(body==null)return null;if(typeof body!=='string')return body;try{return JSON.parse(body);}catch{return null;}}
  function guardDirectFiscalWrite(path,options={}){
    const method=String(options.method||'GET').toUpperCase(),table=(String(path||'').match(/\/rest\/v1\/([^?]+)/)||[])[1];
    if(!table||!['POST','PATCH','PUT','DELETE'].includes(method))return;
    if(table==='document_lines'&&method==='DELETE')throw Object.assign(new Error('La modification des lignes d’un document commercial exige le service transactionnel Supabase.'),{code:'fiscal_rpc_required'});
    if(table!=='documents')return;
    if(method==='DELETE')throw Object.assign(new Error('La suppression d’un document commercial exige le service transactionnel Supabase.'),{code:'fiscal_rpc_required'});
    const payload=parsedRequestBody(options.body),rows=Array.isArray(payload)?payload:[payload||{}];
    if(method==='POST'&&rows.some(row=>FISCAL_DOCUMENT_TYPES.has(String(row.document_type||''))))throw Object.assign(new Error('La création d’un document fiscal exige le service transactionnel Supabase.'),{code:'fiscal_rpc_required'});
    if(['PATCH','PUT'].includes(method)&&rows.some(row=>Object.keys(row).some(key=>FISCAL_DOCUMENT_FIELDS.has(key))))throw Object.assign(new Error('La modification fiscale exige le service transactionnel Supabase.'),{code:'fiscal_rpc_required'});
  }
  function translateError(message,status){
    const value=String(message||'').toLowerCase();
    if(value.includes('rate limit')||status===429)return'Trop de tentatives ont été effectuées. Réessayez plus tard.';
    if(value.includes('duplicate key')||value.includes('23505'))return'Cette valeur existe déjà. Vérifiez la numérotation ou les champs uniques.';
    if(value.includes('jwt expired')||value.includes('session')&&value.includes('expired')||status===401)return'Votre session a expiré. Veuillez vous reconnecter.';
    if(value.includes('failed to fetch')||value.includes('network')||status===0)return'Impossible de contacter le serveur. Vérifiez votre connexion.';
    if(value.includes('forbidden')||value.includes('row-level security')||status===403)return'Vous n’avez pas l’autorisation d’effectuer cette action.';
    if(value.includes('company_onboarding_required'))return'Complétez la raison sociale, le SIRET, l’e-mail et l’adresse de l’entreprise avant de finaliser ce document.';
    if(value.includes('document_client_required'))return'Sélectionnez un client actif avant de finaliser ce document.';
    if(value.includes('document_lines_required'))return'Ajoutez au moins une ligne avec une désignation et une quantité supérieure à zéro.';
    if(value.includes('document_total_must_be_positive'))return'Le total du document doit être supérieur à zéro avant la finalisation.';
    if(value.includes('quote_validity_date_required'))return'Renseignez la date de validité du devis avant de le finaliser.';
    if(value.includes('invalid_document_state')||value.includes('document_is_locked'))return'Ce document ne peut plus être modifié dans son état actuel.';
    if(value.includes('invalid input syntax for type uuid')||value.includes('22p02'))return'Une référence sélectionnée n’est plus valide. Rechargez la page puis sélectionnez-la à nouveau.';
    if(value.includes('foreign key')||value.includes('23503'))return'Un client, un article ou un modèle sélectionné n’existe plus. Rechargez les données puis réessayez.';
    if(value.includes('validated_document_is_locked'))return'Ce document validé est verrouillé. Créez une correction ou un avoir.';
    if(value.includes('schema cache')||value.includes('does not exist')||value.includes('pgrst204'))return'La base de données doit être synchronisée avant cette opération.';
    if(value.includes('payment_exceeds_balance'))return'Le paiement dépasse le reste à payer.';
    if(value.includes('invalid_invoice_state'))return'Cette facture ne peut pas être modifiée dans son état actuel.';
    if(value.includes('invalid_quantity'))return'La quantité doit être supérieure à zéro.';
    return message||'Une erreur est survenue.';
  }
  async function request(path,options={}){
    const runtime=global.PilozRuntime;if(!runtime?.config||!runtime?.session) throw new Error('Authentification requise.');
    guardDirectFiscalWrite(path,options);
    const response=await runtime.request(path,options);
    let data;
    try{data=await readBody(response,path);}catch(error){if(!response.ok)technicalLog('Réponse d’erreur illisible',response,path,error);throw error;}
    if(!response.ok){const message=typeof data==='object'&&data?(data.error||data.message||data.details):'Une erreur est survenue.',failure=new Error(translateError(message,response.status));failure.status=response.status;failure.code=data?.code||data?.error_code||'';technicalLog('Requête refusée',response,path,failure);throw failure;}
    if(data&&typeof data==='object'&&Object.prototype.hasOwnProperty.call(data,'text')){technicalLog('Réponse réussie non JSON',response,path);const failure=new Error('Le serveur a renvoyé une réponse inattendue. Réessayez dans quelques instants.');failure.status=response.status;failure.code='unexpected_content_type';throw failure;}
    return data;
  }
  async function companyContext(){
    let rows=await request('/rest/v1/user_preferences?select=company_id&user_id=eq.'+encodeURIComponent(global.PilozRuntime.session.user_id));
    if(!rows[0]?.company_id){await rpc('ensure_user_company',{company_name:'Mon entreprise'});rows=await request('/rest/v1/user_preferences?select=company_id&user_id=eq.'+encodeURIComponent(global.PilozRuntime.session.user_id));}
    if(!rows[0]?.company_id)throw new Error("Aucune entreprise n'est associée à ce compte.");return rows[0].company_id;
  }
  async function invoke(name,body,signal){
    const runtime=global.PilozRuntime,response=await fetch(runtime.config.url.replace(/\/$/,'')+'/functions/v1/'+name,{method:'POST',signal,headers:{apikey:runtime.config.key,Authorization:'Bearer '+runtime.session.access_token,'Content-Type':'application/json'},body:serializeBody(body)});
    const data=await readBody(response,'/functions/v1/'+name);if(!response.ok){const failure=new Error(translateError(data?.error||data?.message||'Service indisponible.',response.status));failure.status=response.status;failure.code=data?.code||'';technicalLog('Edge Function refusée',response,name,failure);throw failure;}return data;
  }
  async function invokeBlob(name,body,signal){
    const runtime=global.PilozRuntime,response=await fetch(runtime.config.url.replace(/\/$/,'')+'/functions/v1/'+name,{method:'POST',signal,headers:{apikey:runtime.config.key,Authorization:'Bearer '+runtime.session.access_token,'Content-Type':'application/json'},body:serializeBody(body)});
    if(!response.ok){const data=await readBody(response,'/functions/v1/'+name),failure=new Error(translateError(data?.error||data?.message||'Service indisponible.',response.status));failure.status=response.status;failure.code=data?.code||'';technicalLog('Edge Function refusée',response,name,failure);throw failure;}
    const contentType=String(response.headers?.get?.('content-type')||'').split(';')[0].trim().toLowerCase();
    if(!contentType||(!contentType.startsWith('application/pdf')&&!contentType.startsWith('application/octet-stream'))){technicalLog('Réponse binaire inattendue',response,name);const failure=new Error('Le service n’a pas renvoyé un PDF valide. Réessayez dans quelques instants.');failure.status=response.status;failure.code='unexpected_binary_content_type';throw failure;}
    const blob=await response.blob();if(!blob.size){const failure=new Error('Le PDF généré est vide. Réessayez dans quelques instants.');failure.status=response.status;failure.code='empty_pdf_response';throw failure;}return blob;
  }
  async function upsertCompanySettings(companyId,data){return request('/rest/v1/company_settings?on_conflict=company_id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=representation'},body:serializeBody({company_id:companyId,...data})});}
  function query(table,params=''){return request(`/rest/v1/${table}?${params}`);}
  async function queryAll(table,params='',pageSize=1000){
    const size=Math.max(1,Math.min(1000,Number(pageSize)||1000)),rows=[];
    for(let offset=0;;offset+=size){
      const page=await query(table,`${params}${params?'&':''}limit=${size}&offset=${offset}`);
      if(!Array.isArray(page))throw Object.assign(new Error('Le serveur n\u2019a pas renvoy\u00e9 une liste pagin\u00e9e valide.'),{code:'invalid_paginated_response'});
      rows.push(...page);
      if(page.length<size)break;
    }
    return rows;
  }
  const restrictedReturns=new Set(['catalog_items','documents','document_lines','stock_movements']);
  function insert(table,data){return request(`/rest/v1/${table}${restrictedReturns.has(table)?'?select=id':''}`,{method:'POST',headers:{Prefer:'return=representation'},body:serializeBody(data)});}
  function update(table,id,data){return request(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}${restrictedReturns.has(table)?'&select=id':''}`,{method:'PATCH',headers:{Prefer:'return=representation'},body:serializeBody(data)});}
  function remove(table,id){return request(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}`,{method:'DELETE',headers:{Prefer:'return=minimal'}});}
  function rpc(name,args={}){return request(`/rest/v1/rpc/${name}`,{method:'POST',body:serializeBody(args)});}
  async function upload(bucket,path,file,upsert=true){const runtime=global.PilozRuntime,response=await fetch(`${runtime.config.url.replace(/\/$/,'')}/storage/v1/object/${bucket}/${path}`,{method:'POST',headers:{apikey:runtime.config.key,Authorization:`Bearer ${runtime.session.access_token}`,'Content-Type':file.type,'x-upsert':String(upsert)},body:file}),data=await readBody(response,`/storage/v1/object/${bucket}`);if(!response.ok){const failure=new Error(data?.message||data?.error||'Envoi impossible.');failure.status=response.status;technicalLog('Envoi de fichier refusé',response,bucket,failure);throw failure;}return data;}
  async function signedUrl(bucket,path,expiresIn=3600){
    const data=await request(`/storage/v1/object/sign/${bucket}/${path}`,{method:'POST',body:serializeBody({expiresIn})});
    const raw=data?.signedURL||data?.signedUrl||data?.url||'';
    if(!raw||/^https?:\/\//i.test(raw))return data;
    const base=(global.PilozRuntime?.config?.url||'').replace(/\/$/,''),full=base+(raw.startsWith('/storage/v1')?raw:raw.startsWith('/')?'/storage/v1'+raw:'/storage/v1/'+raw);
    return{...data,signedURL:full,signedUrl:full,url:full};
  }
  global.PilozERP={request,companyContext,invoke,invokeBlob,upsertCompanySettings,query,queryAll,insert,update,remove,rpc,upload,signedUrl,translateError,readBody,serializeBody};
})(window);
