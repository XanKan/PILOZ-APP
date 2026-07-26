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
      global.PilozSiteOffer?.captureUser(user);
      if(global.PilozOAuthSessionPending){
        const session=global.PilozRuntime.session;
        session.user_id=user.id;session.email=user.email||'';
        try{localStorage.setItem('piloz_ses',JSON.stringify(session));}catch{}
        let context={};try{context=JSON.parse(sessionStorage.getItem('piloz_oauth_context_v1')||'{}');sessionStorage.removeItem('piloz_oauth_context_v1');}catch{}
        global.PilozOAuthSessionPending=false;
        const completed=await global.authSyncSession?.({remember:true,requireCheckout:!!context.checkout});
        if(completed!==false){history.replaceState(null,'',location.pathname+'#dashboard');global.render?.();}
        return;
      }
      try{
        await global.PilozCheckoutClaim?.verifyLicenseAccess?.();
      }catch(error){
        console.warn('[PILOZ Licence] Session refusée',{code:error?.code||'license_required'});
        global.invalidateAuthSession?.(error?.message||'Aucune licence Piloz active n’est associée à ce compte.');
        global.pageAuth?.();return;
      }
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
