(function(global){
  function translateError(message,status){
    const value=String(message||'').toLowerCase();
    if(value.includes('rate limit')||status===429)return'Trop de tentatives ont été effectuées. Réessayez plus tard.';
    if(value.includes('duplicate key')||value.includes('23505'))return'Cette valeur existe déjà. Vérifiez la numérotation ou les champs uniques.';
    if(value.includes('jwt expired')||value.includes('session')&&value.includes('expired')||status===401)return'Votre session a expiré. Veuillez vous reconnecter.';
    if(value.includes('failed to fetch')||value.includes('network')||status===0)return'Impossible de contacter le serveur. Vérifiez votre connexion.';
    if(value.includes('forbidden')||value.includes('row-level security')||status===403)return'Vous n’avez pas l’autorisation d’effectuer cette action.';
    if(value.includes('payment_exceeds_balance'))return'Le paiement dépasse le reste à payer.';
    if(value.includes('invalid_invoice_state'))return'Cette facture ne peut pas être modifiée dans son état actuel.';
    if(value.includes('invalid_quantity'))return'La quantité doit être supérieure à zéro.';
    return message||'Une erreur est survenue.';
  }
  async function request(path,options={}){
    const runtime=global.PilozRuntime;if(!runtime?.config||!runtime?.session) throw new Error('Authentification requise.');
    const response=await runtime.request(path,options);
    if(!response.ok){let message='Une erreur est survenue.';try{const data=await response.json();message=data.error||data.message||data.details||message;}catch{}throw new Error(translateError(message,response.status));}
    if(response.status===204)return null;return response.json();
  }
  async function companyContext(){
    let rows=await request('/rest/v1/user_preferences?select=company_id&user_id=eq.'+encodeURIComponent(global.PilozRuntime.session.user_id));
    if(!rows[0]?.company_id){await rpc('ensure_user_company',{company_name:'Mon entreprise'});rows=await request('/rest/v1/user_preferences?select=company_id&user_id=eq.'+encodeURIComponent(global.PilozRuntime.session.user_id));}
    if(!rows[0]?.company_id)throw new Error("Aucune entreprise n'est associée à ce compte.");return rows[0].company_id;
  }
  async function invoke(name,body,signal){
    const runtime=global.PilozRuntime,response=await fetch(runtime.config.url.replace(/\/$/,'')+'/functions/v1/'+name,{method:'POST',signal,headers:{apikey:runtime.config.key,Authorization:'Bearer '+runtime.session.access_token,'Content-Type':'application/json'},body:JSON.stringify(body)});
    const data=await response.json().catch(()=>({}));if(!response.ok)throw new Error(translateError(data.error||data.message||'Service indisponible.',response.status));return data;
  }
  async function upsertCompanySettings(companyId,data){return request('/rest/v1/company_settings?on_conflict=company_id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=representation'},body:JSON.stringify({company_id:companyId,...data})});}
  function query(table,params=''){return request(`/rest/v1/${table}?${params}`);}
  const restrictedReturns=new Set(['catalog_items','documents','document_lines','stock_movements']);
  function insert(table,data){return request(`/rest/v1/${table}${restrictedReturns.has(table)?'?select=id':''}`,{method:'POST',headers:{Prefer:'return=representation'},body:JSON.stringify(data)});}
  function update(table,id,data){return request(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}${restrictedReturns.has(table)?'&select=id':''}`,{method:'PATCH',headers:{Prefer:'return=representation'},body:JSON.stringify(data)});}
  function remove(table,id){return request(`/rest/v1/${table}?id=eq.${encodeURIComponent(id)}`,{method:'DELETE',headers:{Prefer:'return=minimal'}});}
  function rpc(name,args={}){return request(`/rest/v1/rpc/${name}`,{method:'POST',body:JSON.stringify(args)});}
  async function upload(bucket,path,file,upsert=true){const runtime=global.PilozRuntime,response=await fetch(`${runtime.config.url.replace(/\/$/,'')}/storage/v1/object/${bucket}/${path}`,{method:'POST',headers:{apikey:runtime.config.key,Authorization:`Bearer ${runtime.session.access_token}`,'Content-Type':file.type,'x-upsert':String(upsert)},body:file});if(!response.ok)throw new Error((await response.json().catch(()=>({}))).message||'Envoi impossible.');return response.json();}
  async function signedUrl(bucket,path,expiresIn=3600){return request(`/storage/v1/object/sign/${bucket}/${path}`,{method:'POST',body:JSON.stringify({expiresIn})});}
  global.PilozERP={request,companyContext,invoke,upsertCompanySettings,query,insert,update,remove,rpc,upload,signedUrl,translateError};
})(window);
