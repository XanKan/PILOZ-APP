(function(global){
  function requestedMode(){
    const mode=new URLSearchParams(location.search).get('mode');
    return mode==='login'||mode==='signup'?mode:'';
  }

  function showChecking(){
    document.body.classList.add('auth-checking');
    document.body.classList.remove('auth-only');
    global.clearPrivateShell?.();
  }

  async function requestCurrentUser(){
    const config=global.PilozRuntime?.config,session=global.PilozRuntime?.session;
    if(!config?.url||!config?.key||!session?.access_token)return null;
    const getUser=()=>fetch(config.url.replace(/\/$/,'')+'/auth/v1/user',{headers:{apikey:config.key,Authorization:'Bearer '+global.PilozRuntime.session.access_token}});
    let response=await getUser();
    if(response.status===401&&global.PilozRuntime.session?.refresh_token&&await global.rafraichir?.())response=await getUser();
    if(!response.ok)return null;
    const user=await response.json().catch(()=>null);
    return user?.id?user:null;
  }

  async function boot(){
    showChecking();
    if(requestedMode()||!global.PilozRuntime?.session){
      global.pageAuth?.();
      return;
    }
    try{
      const user=await requestCurrentUser();
      if(!user){
        global.invalidateAuthSession?.('Votre session a expiré. Veuillez vous reconnecter.');
        global.pageAuth?.();
        return;
      }
      global.PilozCurrentUser=user;
      await global.charger?.();
    }catch(error){
      console.error('Échec du démarrage sécurisé de Piloz',error);
      global.invalidateAuthSession?.('Impossible de vérifier votre session. Veuillez vous reconnecter.');
      global.pageAuth?.();
    }
  }

  global.PilozAuthGuard={boot,requestCurrentUser};
  setTimeout(boot,0);
})(window);
