const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

let resolveInvoke;
const nodes=new Map();
const panel={hidden:true};
const floatingBody={innerHTML:''};
const body={
 appendChild(node){nodes.set(node.id,node);if(node.id==='pilo-floating-root'){nodes.set('pilo-floating-root',node);}if(node.id==='piloz-ticket-overlay-root')nodes.set(node.id,node);return node;}
};
const document={
 body,
 documentElement:{dataset:{appVersion:'test'}},
 createElement(){return{id:'',innerHTML:'',dataset:{},className:'',setAttribute(){},toggleAttribute(){}};},
 getElementById(id){return nodes.get(id)||null;},
 querySelector(selector){if(selector==='.pilo-floating-panel')return panel;if(selector==='.pilo-floating-body')return floatingBody;return null;},
 querySelectorAll(selector){return selector==='.pilo-thread'?[{scrollTop:0,scrollHeight:100}]:[];},
 addEventListener(){}
};
class TestFormData{
 constructor(form){this.form=form;}
 get(name){return this.form.values?.[name]||'';}
}
const context={
 console,document,location:{hash:'#dashboard',href:'https://app.piloz.fr/#dashboard'},
 URL,Intl,setTimeout,clearTimeout,queueMicrotask,FormData:TestFormData,
 PilozRuntime:{session:{user_id:'11111111-1111-4111-8111-111111111111'}},
 PilozERP:{
  invoke(){return new Promise(resolve=>{resolveInvoke=resolve;});},
  rpc:async()=>[],query:async()=>[],request:async()=>({})
 },
 PilozApp:{getState:()=>({companyId:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',permissions:[]}),go(){},render(){}},
 PilozModern:{renderNavigation(){},renderRoute(){return false;}},
 open(){},toast(){},window:null
};
context.window=context;
vm.createContext(context);
vm.runInContext(fs.readFileSync('assets/js/modules/erp/erp-help-support.js','utf8'),context,{filename:'erp-help-support.js'});

(async()=>{
 await Promise.resolve();
 context.PilozHelp.togglePilo();
 assert.equal(panel.hidden,false,'le chat flottant doit être ouvert');
 const form={values:{question:'Comment finaliser une facture ?'},reset(){this.values={};}};
 const pending=context.PilozHelp.askPilo(form);
 assert.match(floatingBody.innerHTML,/Comment finaliser une facture/,'le message utilisateur doit apparaître avant la réponse réseau');
 assert.match(floatingBody.innerHTML,/Pilo prépare sa réponse/,'l’état de réponse IA doit apparaître immédiatement');
 resolveInvoke({answer:'Voici la procédure officielle.',answerLevel:'high',sources:[],canCreateTicket:false});
 await pending;
 assert.match(floatingBody.innerHTML,/Voici la procédure officielle/,'la réponse doit apparaître sans fermer le chat');

 context.PilozHelp.openTicket();
 const overlay=nodes.get('piloz-ticket-overlay-root');
 assert.match(overlay.innerHTML,/Créer un ticket support/,'le formulaire de ticket doit être visible depuis une page hors Aide');
 console.log(JSON.stringify({ok:true,instantUserMessage:true,instantAssistantMessage:true,floatingTicket:true}));
})().catch(error=>{console.error(error);process.exit(1);});
