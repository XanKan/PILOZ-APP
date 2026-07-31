import { createClient } from "npm:@supabase/supabase-js@2";

type Body={action?:string;payload?:Record<string,unknown>};
type AdminContext={id:string;user_id:string;role:string;status:string;first_name?:string;last_name?:string;email:string;mfa_required:boolean;aal:string;permissions:string[]};

const allowedOrigins=new Set(["https://admin.piloz.fr","http://localhost:4173","http://localhost:5173"]);
function cors(req:Request){const origin=req.headers.get("origin")||"";return{
 "Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://admin.piloz.fr",
 "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type, x-request-id",
 "Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"
};}
function response(req:Request,data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function text(value:unknown,max=200){return String(value??"").trim().slice(0,max);}
function integer(value:unknown,fallback:number,min=1,max=100){const parsed=Number(value);return Number.isFinite(parsed)?Math.max(min,Math.min(max,Math.trunc(parsed))):fallback;}
function uuid(value:unknown){const result=text(value,40);if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result))throw new Error("Identifiant invalide");return result;}
function email(value:unknown){const result=text(value,254).toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(result))throw new Error("Adresse e-mail invalide");return result;}
function record(value:unknown){return value&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}
function slug(value:unknown){return text(value,180).normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"").slice(0,120);}
function oneOf(value:unknown,allowed:string[],fallback?:string){const result=text(value,80);if(allowed.includes(result))return result;if(fallback!==undefined)return fallback;throw new Error("Valeur non autorisée");}
function safeFileName(value:unknown){const original=text(value,240).replace(/[\u0000-\u001f\u007f]/g,"");if(!original||original.includes("/")||original.includes("\\"))throw new Error("Nom de fichier invalide");const extension=(original.split(".").pop()||"").toLowerCase();const base=original.normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-zA-Z0-9._-]+/g,"-").replace(/^-+|-+$/g,"").slice(0,180)||"fichier";return{original,extension,storage:base};}
function bytesFromBase64(value:string){try{const binary=atob(value),bytes=new Uint8Array(binary.length);for(let index=0;index<binary.length;index++)bytes[index]=binary.charCodeAt(index);return bytes;}catch{throw new Error("Contenu de fichier invalide");}}
const knowledgeAttachmentTypes:Record<string,Set<string>>={"application/pdf":new Set(["pdf"]),"image/png":new Set(["png"]),"image/jpeg":new Set(["jpg","jpeg"]),"image/webp":new Set(["webp"]),"image/gif":new Set(["gif"]),"text/plain":new Set(["txt","log","md"]),"text/markdown":new Set(["md"]),"application/vnd.openxmlformats-officedocument.wordprocessingml.document":new Set(["docx"]),"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":new Set(["xlsx"])};

Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return response(req,{error:"Méthode non autorisée"},405);
 const origin=req.headers.get("origin")||"";
 if(origin&&!allowedOrigins.has(origin))return response(req,{error:"Origine non autorisée"},403);
 const authorization=req.headers.get("authorization");
 if(!authorization?.startsWith("Bearer "))return response(req,{error:"Authentification requise"},401);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY");
 if(!url||!anon)return response(req,{error:"Configuration serveur indisponible"},503);
 const client=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
 const {data:{user},error:userError}=await client.auth.getUser();
 if(userError||!user)return response(req,{error:"Session invalide"},401);
 const {data:rawContext,error:contextError}=await client.rpc("platform_admin_context");
 if(contextError||!rawContext)return response(req,{error:"Accès réservé à l’équipe Piloz"},403);
 const context=rawContext as AdminContext;
 if(context.status!=="active")return response(req,{error:"Compte administrateur suspendu"},403);
 if(context.mfa_required&&context.aal!=="aal2")return response(req,{error:"Authentification multifacteur requise",code:"mfa_required"},403);
 let body:Body;
 try{body=await req.json();}catch{return response(req,{error:"Requête invalide"},400);}
 const action=text(body.action,80),payload=body.payload||{},permissions=new Set(context.permissions||[]);
 const requirePermission=(permission:string)=>{if(!permissions.has(permission))throw Object.assign(new Error("Action non autorisée"),{status:403});};
 const privileged=()=>{const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");if(!key)throw Object.assign(new Error("Opération serveur non configurée"),{status:503});return createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});};
 const audit=async(actionName:string,targetType:string,targetId:string|null,companyId:string|null,oldState:unknown,newState:unknown,reason?:unknown)=>{
  const {error}=await client.rpc("append_platform_admin_audit",{target_action:actionName,target_type:targetType,target_id:targetId,target_company_id:companyId,old_state:oldState??null,new_state:newState??null,target_reason:text(reason,500)||null});
  if(error)throw error;
 };
 try{
  if(action==="context"){await client.rpc("platform_admin_register_session",{target_user_agent:text(req.headers.get("user-agent"),500)||null});return response(req,{context});}
  const {data:sessionActive,error:sessionError}=await client.rpc("platform_admin_validate_and_touch_session");
  if(sessionError||!sessionActive)return response(req,{error:"Session administrateur expirée ou révoquée",code:"admin_session_expired"},401);
  if(action==="dashboard"){
   requirePermission("companies.read");const {data,error}=await client.rpc("platform_admin_dashboard");if(error)throw error;return response(req,{dashboard:data});
  }
  if(action==="companies.list"){
   requirePermission("companies.read");const {data,error}=await client.rpc("platform_admin_list_companies_v2",{
    search_text:text(payload.search,160)||null,status_filter:text(payload.status,40)||null,plan_filter:text(payload.plan,40)||null,
    page_number:integer(payload.page,1,1,1_000_000),page_size:integer(payload.pageSize,25,1,100)
   });if(error)throw error;return response(req,{items:data||[],total:Number(data?.[0]?.total_count||0)});
  }
  if(action==="companies.detail"){
   requirePermission("companies.read");const companyId=uuid(payload.companyId);
   const [company,settings,subscription,members,features,events,support,billing,compliance,anomalies,privacy]=await Promise.all([
    client.from("companies").select("id,name,owner_user_id,platform_status,suspension_level,suspended_at,suspension_reason,internal_admin_notes,admin_tags,created_at,updated_at").eq("id",companyId).maybeSingle(),
    client.from("company_settings").select("*").eq("company_id",companyId).maybeSingle(),
    client.from("subscriptions").select("*").eq("company_id",companyId).maybeSingle(),
    client.rpc("platform_admin_list_users",{target_company_id:companyId,page_number:1,page_size:100}),
    client.from("company_feature_overrides").select("id,feature_key,enabled,starts_at,ends_at,reason,created_at").eq("company_id",companyId).order("created_at",{ascending:false}),
    client.from("subscription_events").select("id,event_type,reason,financial_impact_cents,effective_at,created_at").eq("company_id",companyId).order("created_at",{ascending:false}).limit(50),
    client.from("support_sessions").select("id,reason,mode,started_at,expires_at,ended_at").eq("company_id",companyId).order("started_at",{ascending:false}).limit(20),
    permissions.has("billing.read")?client.from("platform_billing_invoices").select("id,number,period_start,period_end,amount_excl_tax_cents,tax_cents,amount_incl_tax_cents,paid_cents,status,issued_at,due_at,provider").eq("company_id",companyId).order("created_at",{ascending:false}).limit(50):Promise.resolve({data:[],error:null}),
    permissions.has("compliance.read")?client.from("company_fiscal_configurations").select("mode,activation_status,application_version,schema_version,signing_status,updated_at").eq("company_id",companyId).maybeSingle():Promise.resolve({data:null,error:null}),
    permissions.has("compliance.read")?client.from("compliance_anomalies").select("id,anomaly_type,severity,source,detected_at").eq("company_id",companyId).order("detected_at",{ascending:false}).limit(50):Promise.resolve({data:[],error:null}),
    permissions.has("privacy.read")?client.from("data_subject_requests").select("id,request_type,subject_kind,received_at,identity_verified_at,due_at,status,closed_at").eq("company_id",companyId).order("received_at",{ascending:false}).limit(50):Promise.resolve({data:[],error:null})
   ]);
   const firstError=[company,settings,subscription,members,features,events,support,billing,compliance,anomalies,privacy].find(result=>result.error)?.error;if(firstError)throw firstError;
   if(!company.data)return response(req,{error:"Entreprise introuvable"},404);
   return response(req,{company:company.data,settings:settings.data,subscription:subscription.data,members:members.data||[],features:features.data||[],events:events.data||[],support:support.data||[],billing:billing.data||[],compliance:compliance.data,anomalies:anomalies.data||[],privacy:privacy.data||[]});
  }
  if(action==="companies.create"){
   requirePermission("companies.write");requirePermission("users.write");const companyValues=record(payload.company),subscriptionValues=record(payload.subscription);
   const firstName=text(companyValues.owner_first_name,100),lastName=text(companyValues.owner_last_name,100),ownerEmail=email(companyValues.owner_email);
   if(!firstName||!lastName)throw Object.assign(new Error("Le prénom et le nom du propriétaire sont obligatoires."),{status:400});
   companyValues.provisioning_name=text(companyValues.provisioning_name,180)||`Entreprise à configurer — ${firstName} ${lastName}`;
   const ownerUserId=payload.ownerUserId?uuid(payload.ownerUserId):null;let userId=ownerUserId;
   if(!userId){const {data,error}=await privileged().auth.admin.inviteUserByEmail(ownerEmail,{data:{first_name:firstName,last_name:lastName},redirectTo:"https://app.piloz.fr/?mode=login"});if(error||!data.user)throw Object.assign(new Error(error?.message?.toLowerCase().includes("already")?"Ce propriétaire existe déjà. Ajoutez-le depuis sa fiche utilisateur.":"L’invitation du propriétaire a échoué."),{status:error?.status||400});userId=data.user.id;}
   const {data,error}=await client.rpc("platform_admin_create_company",{target_owner_user_id:userId,target_company:companyValues,target_subscription:subscriptionValues,target_reason:text(payload.reason,500)});if(error)throw error;
   return response(req,{company:data,ownerUserId:userId,invitationSent:!ownerUserId,message:!ownerUserId?"Invitation envoyée. Si elle n’apparaît pas dans quelques minutes, vérifiez les courriers indésirables (spams).":"Entreprise créée."},201);
  }
  if(action==="demo_accounts.create"){
   requirePermission("companies.write");requirePermission("users.write");requirePermission("subscriptions.write");
   const firstName=text(payload.firstName,100),lastName=text(payload.lastName,100),ownerEmail=email(payload.email),reason=text(payload.reason,500)||`Création d'un compte de démonstration pour ${ownerEmail}`;
   if(!firstName||!lastName)throw Object.assign(new Error("Le prénom et le nom sont obligatoires."),{status:400});
   const service=privileged();let createdCompanyId:string|null=null,createdUserId:string|null=null;
   try{
    const {data:existing}=await service.auth.admin.listUsers({page:1,perPage:1000});
    if(existing?.users.some(candidate=>candidate.email?.toLowerCase()===ownerEmail))throw Object.assign(new Error("Un compte existe déjà avec cette adresse e-mail."),{status:409});
    const {data:plans,error:planError}=await service.from("subscription_plan_versions").select("id,plan_key,name,availability,recommended,price_monthly_cents").is("effective_to",null).order("recommended",{ascending:false}).order("price_monthly_cents",{ascending:true}).limit(50);
    const plan=plans?.find(candidate=>candidate.availability==="available")||null;
    if(planError)throw planError;if(!plan)throw Object.assign(new Error("Aucun plan actif n'est disponible pour l'essai."),{status:409});
    const {data:invitation,error:inviteError}=await service.auth.admin.inviteUserByEmail(ownerEmail,{data:{first_name:firstName,last_name:lastName,demo_account:true},redirectTo:"https://app.piloz.fr/?mode=login"});
    if(inviteError||!invitation.user)throw Object.assign(new Error("L'invitation du compte de démonstration n'a pas pu être envoyée."),{status:inviteError?.status||400});
    createdUserId=invitation.user.id;
    const demoName=`Horizon Conseil — Démo ${firstName} ${lastName}`.slice(0,180);
    const {data:company,error:companyError}=await client.rpc("platform_admin_create_company",{target_owner_user_id:createdUserId,target_company:{owner_first_name:firstName,owner_last_name:lastName,owner_email:ownerEmail,provisioning_name:demoName,provisioning_pending:false,legal_name:"Horizon Conseil (démonstration)",trade_name:"Horizon Conseil",company_type:"company",legal_form:"Société de démonstration",address_line1:"18 avenue des Ateliers",postal_code:"85000",city:"La Roche-sur-Yon",country:"France",country_code:"FR",email:"contact@horizon-conseil.example",phone:"+33100000000",currency:"EUR",language:"fr",admin_tags:["demo","seeded"],internal_admin_notes:"Compte de démonstration Piloz — données entièrement fictives."},target_subscription:{plan_version_id:plan.id,billing_interval:"monthly",status:"trialing",trial_days:14,max_users:null},target_reason:reason});
    if(companyError)throw companyError;createdCompanyId=company.id;
    const now=new Date(),tomorrow=new Date(now.getTime()+86_400_000),nextWeek=new Date(now.getTime()+7*86_400_000);
    const {error:settingsError}=await service.from("company_settings").update({legal_name:"Horizon Conseil (démonstration)",trade_name:"Horizon Conseil",address_line1:"18 avenue des Ateliers",postal_code:"85000",city:"La Roche-sur-Yon",country:"France",country_code:"FR",email:"contact@horizon-conseil.example",phone_e164:"+33100000000",currency:"EUR",language:"fr",onboarding_step:7,onboarding_completed_at:now.toISOString()}).eq("company_id",createdCompanyId);
    if(settingsError)throw settingsError;
    const {error:preferencesError}=await service.from("user_preferences").update({onboarding_completed:true}).eq("user_id",createdUserId);
    if(preferencesError)throw preferencesError;
    const {data:clients,error:clientsError}=await service.from("clients").insert([
     {company_id:createdCompanyId,kind:"company",legal_name:"Nova Bâtiment",email:"contact@nova-batiment.example",phone_e164:"+33100000001",address_line_1:"12 rue du Chantier",postal_code:"75012",city:"Paris",country_code:"FR",payment_terms:"30 jours",created_by:createdUserId},
     {company_id:createdCompanyId,kind:"company",legal_name:"Atelier Horizon",email:"bonjour@atelier-horizon.example",phone_e164:"+33100000002",address_line_1:"4 place des Artisans",postal_code:"44000",city:"Nantes",country_code:"FR",payment_terms:"À réception",created_by:createdUserId},
     {company_id:createdCompanyId,kind:"person",first_name:"Camille",last_name:"Martin",email:"camille.martin@example.com",phone_e164:"+33100000003",postal_code:"69002",city:"Lyon",country_code:"FR",created_by:createdUserId}
    ]).select("id,legal_name,first_name,last_name");
    if(clientsError)throw clientsError;
    const {error:itemsError}=await service.from("catalog_items").insert([
     {company_id:createdCompanyId,item_type:"service",reference:"DEMO-SRV-001",name:"Audit organisationnel",short_description:"Diagnostic et recommandations",unit:"forfait",purchase_price:350,sale_price:750,tax_rate:20,stock_managed:false,created_by:createdUserId},
     {company_id:createdCompanyId,item_type:"subscription",reference:"DEMO-ABO-001",name:"Accompagnement mensuel",short_description:"Suivi et pilotage mensuels",unit:"mois",purchase_price:250,sale_price:590,tax_rate:20,stock_managed:false,created_by:createdUserId},
     {company_id:createdCompanyId,item_type:"product",reference:"DEMO-ART-001",name:"Kit de démarrage",short_description:"Matériel de démonstration",unit:"unité",purchase_price:420,sale_price:690,tax_rate:20,stock_managed:false,created_by:createdUserId}
    ]);
    if(itemsError)throw itemsError;
    const nova=clients?.find(item=>item.legal_name==="Nova Bâtiment"),atelier=clients?.find(item=>item.legal_name==="Atelier Horizon");
    const {error:activitiesError}=await service.from("activities").insert([
     {company_id:createdCompanyId,client_id:nova?.id||null,activity_type:"call",subject:"Appeler Nova Bâtiment",description:"Préparer la proposition commerciale (donnée fictive).",scheduled_at:tomorrow.toISOString(),assigned_user_id:createdUserId,created_by:createdUserId,metadata:{demo:true}},
     {company_id:createdCompanyId,client_id:atelier?.id||null,activity_type:"meeting",subject:"Rendez-vous Atelier Horizon",description:"Présentation de la solution (donnée fictive).",scheduled_at:nextWeek.toISOString(),assigned_user_id:createdUserId,created_by:createdUserId,metadata:{demo:true}},
     {company_id:createdCompanyId,client_id:atelier?.id||null,activity_type:"email",subject:"Envoyer le compte rendu",description:"Activité terminée de démonstration.",scheduled_at:now.toISOString(),completed_at:now.toISOString(),assigned_user_id:createdUserId,created_by:createdUserId,metadata:{demo:true}}
    ]);
    if(activitiesError)throw activitiesError;
    await audit("demo_account.create","company",createdCompanyId,createdCompanyId,null,{email:ownerEmail,trial_days:14,plan_key:plan.plan_key,seeded:true},reason);
    return response(req,{company,ownerUserId:createdUserId,invitationSent:true,trialDays:14,message:"Compte de démonstration créé. L'invitation sécurisée a été envoyée ; le destinataire choisira son mot de passe."},201);
   }catch(error){
    if(createdCompanyId)await service.from("companies").delete().eq("id",createdCompanyId);
    if(createdUserId)await service.auth.admin.deleteUser(createdUserId);
    throw error;
   }
  }
  if(action==="demo_accounts.list"){
   requirePermission("companies.read");const service=privileged();
    const {data,error}=await service.from("companies").select("id,name,owner_user_id,platform_status,created_at,admin_tags,company_settings(email,trade_name),subscriptions(plan_key,status,trial_started_at,trial_ends_at)").contains("admin_tags",["demo"]).order("created_at",{ascending:false}).limit(200);
    if(error)throw error;
    const items=await Promise.all((data||[]).map(async item=>{
     const {data:owner}=await service.auth.admin.getUserById(item.owner_user_id);
     return {...item,owner_email:owner.user?.email||null};
    }));
    return response(req,{items});
  }
  if(action==="companies.update"){
   requirePermission("companies.write");const {data,error}=await client.rpc("platform_admin_update_company",{target_company_id:uuid(payload.companyId),target_changes:record(payload.changes),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{company:data});
  }
  if(action==="companies.export"){
   requirePermission("privacy.read");const {data,error}=await client.rpc("platform_admin_export_company",{target_company_id:uuid(payload.companyId),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{export:data});
  }
  if(action==="users.list"){
   requirePermission("users.read");const {data,error}=await client.rpc("platform_admin_list_users",{
    search_text:text(payload.search,160)||null,target_company_id:payload.companyId?uuid(payload.companyId):null,
    page_number:integer(payload.page,1,1,1_000_000),page_size:integer(payload.pageSize,25,1,100)
   });if(error)throw error;return response(req,{items:data||[],total:Number(data?.[0]?.total_count||0)});
  }
  if(action==="users.invite"){
   requirePermission("users.write");const companyId=uuid(payload.companyId),targetEmail=email(payload.email),role=text(payload.role,20)||"member";
   const {data:invitation,error:inviteError}=await privileged().auth.admin.inviteUserByEmail(targetEmail,{data:{first_name:text(payload.firstName,100),last_name:text(payload.lastName,100)},redirectTo:"https://app.piloz.fr/?mode=login"});
   if(inviteError||!invitation.user)throw Object.assign(new Error(inviteError?.message?.toLowerCase().includes("already")?"Cet utilisateur existe déjà. Utilisez son identifiant pour le rattacher.":"L’invitation n’a pas pu être envoyée."),{status:inviteError?.status||400});
   const reason=text(payload.reason,500)||"Invitation par un administrateur Piloz";
   const {error:memberError}=await client.rpc("platform_admin_manage_company_user",{target_company_id:companyId,target_user_id:invitation.user.id,target_role:role,target_operation:"attach",target_reason:reason});if(memberError)throw memberError;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:invitation.user.id,target_company_id:companyId,target_action:"user.invite",target_reason:reason,target_new_state:{email:targetEmail,role}});
   return response(req,{userId:invitation.user.id,invitationSent:true,message:"Invitation envoyée. Si elle n’apparaît pas dans quelques minutes, vérifiez les courriers indésirables (spams)."},201);
  }
  if(action==="users.manage"){
   requirePermission("users.write");const {data,error}=await client.rpc("platform_admin_manage_company_user",{target_company_id:uuid(payload.companyId),target_user_id:uuid(payload.userId),target_role:text(payload.role,20)||"member",target_operation:text(payload.operation,30),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{membership:data});
  }
  if(action==="users.auth_status"){
   requirePermission("users.write");const userId=uuid(payload.userId),companyId=payload.companyId?uuid(payload.companyId):null,suspended=Boolean(payload.suspended),reason=text(payload.reason,500);
   if(!reason)throw new Error("Le motif est obligatoire");const {data,error}=await privileged().auth.admin.updateUserById(userId,{ban_duration:suspended?"876000h":"none"});if(error)throw error;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:userId,target_company_id:companyId,target_action:suspended?"user.auth_suspended":"user.auth_reactivated",target_reason:reason,target_new_state:{suspended}});
   return response(req,{userId:data.user.id,suspended});
  }
  if(action==="users.activation_email"){
   requirePermission("users.write");const targetEmail=email(payload.email),userId=uuid(payload.userId),companyId=payload.companyId?uuid(payload.companyId):null,reason=text(payload.reason,500);
   if(!reason)throw new Error("Le motif est obligatoire");const {error}=await privileged().auth.resetPasswordForEmail(targetEmail,{redirectTo:"https://app.piloz.fr/?mode=login"});if(error)throw error;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:userId,target_company_id:companyId,target_action:"user.activation_email_resent",target_reason:reason,target_new_state:{requested:true}});
   return response(req,{sent:true});
  }
  if(action==="users.password_reset"){
   requirePermission("users.write");const targetEmail=email(payload.email),userId=uuid(payload.userId),companyId=payload.companyId?uuid(payload.companyId):null,reason=text(payload.reason,500);
   if(!reason)throw new Error("Le motif est obligatoire");const {error}=await privileged().auth.resetPasswordForEmail(targetEmail,{redirectTo:"https://app.piloz.fr/?mode=login"});if(error)throw error;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:userId,target_company_id:companyId,target_action:"user.password_reset_requested",target_reason:reason,target_new_state:{requested:true}});
   return response(req,{sent:true});
  }
  if(action==="users.mfa_reset"){
   requirePermission("users.write");const userId=uuid(payload.userId),companyId=payload.companyId?uuid(payload.companyId):null,reason=text(payload.reason,500);
   if(!reason)throw new Error("Le motif est obligatoire");const authAdmin=privileged(),{data:list,error:listError}=await authAdmin.auth.admin.mfa.listFactors({userId});if(listError)throw listError;
   const factors=list?.factors||[];
   for(const factor of factors){const {error}=await authAdmin.auth.admin.mfa.deleteFactor({userId,id:factor.id});if(error)throw error;}
   const {error:auditError}=await client.rpc("platform_admin_record_auth_action",{target_user_id:userId,target_company_id:companyId,target_action:"user.sessions_revoked",target_reason:reason,target_new_state:{mfa_reset_required:true,deleted_factor_count:factors.length}});if(auditError)throw auditError;
   return response(req,{reset:true,deletedFactors:factors.length});
  }
  if(action==="plans.list"){
   requirePermission("plans.read");const {data,error}=await client.from("subscription_plan_versions").select("*").order("plan_key").order("version",{ascending:false});if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="plans.create_version"){
   requirePermission("plans.write");const {data,error}=await client.rpc("platform_admin_create_plan_version",{target_plan_key:text(payload.planKey,60),target_values:record(payload.values),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{plan:data},201);
  }
  if(action==="subscriptions.list"){
   requirePermission("subscriptions.read");const page=integer(payload.page,1,1,1_000_000),pageSize=integer(payload.pageSize,25,1,100);
   let query=client.from("subscriptions").select("*,companies(name),subscription_plan_versions(name)",{count:"exact"}).order("updated_at",{ascending:false}).range((page-1)*pageSize,page*pageSize-1);
   const status=text(payload.status,40),plan=text(payload.plan,40);if(status)query=query.eq("status",status);if(plan)query=query.eq("plan_key",plan);
   const {data,error,count}=await query;if(error)throw error;return response(req,{items:data||[],total:count||0});
  }
  if(action==="revenue.summary"){
   requirePermission("revenue.read");const [dashboard,snapshots,payments,refunds]=await Promise.all([
    client.rpc("platform_admin_dashboard"),client.from("platform_revenue_snapshots").select("*").order("period_start",{ascending:true}).limit(24),
    client.from("platform_billing_payments").select("amount_cents,status,paid_at").eq("status","succeeded").order("paid_at",{ascending:false}).limit(5000),
    client.from("platform_billing_refunds").select("amount_cents,status,refunded_at").eq("status","succeeded").order("refunded_at",{ascending:false}).limit(5000)
   ]);const firstError=[dashboard,snapshots,payments,refunds].find(result=>result.error)?.error;if(firstError)throw firstError;
   return response(req,{summary:dashboard.data,snapshots:snapshots.data||[],payments:payments.data||[],refunds:refunds.data||[],automaticBillingConfigured:Boolean(dashboard.data?.stripe_configured)});
  }
  if(action==="billing.summary"){
   requirePermission("billing.read");const [invoices,payments,refunds,dashboard]=await Promise.all([
    client.from("platform_billing_invoices").select("id,number,company_id,period_start,period_end,amount_excl_tax_cents,tax_cents,amount_incl_tax_cents,paid_cents,status,issued_at,due_at,provider,companies(name)").order("created_at",{ascending:false}).limit(200),
    client.from("platform_billing_payments").select("id,company_id,invoice_id,amount_cents,currency,status,payment_method,paid_at,provider,companies(name)").order("created_at",{ascending:false}).limit(200),
    client.from("platform_billing_refunds").select("id,company_id,payment_id,amount_cents,reason,status,refunded_at,provider,companies(name)").order("created_at",{ascending:false}).limit(200),
    client.rpc("platform_admin_dashboard")
   ]);const firstError=[invoices,payments,refunds,dashboard].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{invoices:invoices.data||[],payments:payments.data||[],refunds:refunds.data||[],automaticBillingConfigured:Boolean(dashboard.data?.stripe_configured)});
  }
  if(action==="audit.list"){
   requirePermission("audit.read");const page=integer(payload.page,1,1,1_000_000),pageSize=integer(payload.pageSize,50,1,100),{data,error,count}=await client.from("platform_admin_audit_events").select("id,admin_id,admin_role,action,target_type,target_id,company_id,reason,occurred_at,result,error_code,event_hash,previous_hash",{count:"exact"}).order("occurred_at",{ascending:false}).range((page-1)*pageSize,page*pageSize-1);if(error)throw error;return response(req,{items:data||[],total:count||0});
  }
  if(action==="support.list"){
   requirePermission("support.read");const {data,error}=await client.from("support_cases").select("*").order("created_at",{ascending:false}).limit(100);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="support.current"){
   requirePermission("support.session");const {data,error}=await client.from("support_sessions").select("id,company_id,reason,mode,started_at,expires_at,companies(name)").eq("admin_id",context.id).is("ended_at",null).gt("expires_at",new Date().toISOString()).order("started_at",{ascending:false}).limit(1).maybeSingle();if(error)throw error;return response(req,{session:data});
  }
  if(action==="support.save"){
   requirePermission("support.write");const {data,error}=await client.rpc("platform_admin_save_support_case",{target_case_id:payload.caseId?uuid(payload.caseId):null,target_values:record(payload.values),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{case:data},payload.caseId?200:201);
  }
  if(action==="documentation.categories"){
   requirePermission("documentation.read");const {data,error}=await privileged().from("knowledge_categories").select("id,parent_id,slug,name,description,position,active,created_at,updated_at").order("position").order("name");if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="documentation.list"){
   requirePermission("documentation.read");const adminClient=privileged(),page=integer(payload.page,1,1,1_000_000),pageSize=integer(payload.pageSize,100,1,200);
   let query=adminClient.from("knowledge_articles").select("id,category_id,slug,title,summary,status,visibility,availability,company_id,language,current_version,published_at,archived_at,last_reviewed_at,created_at,updated_at,knowledge_categories(name,slug)",{count:"exact"}).order("updated_at",{ascending:false}).range((page-1)*pageSize,page*pageSize-1);
   const status=text(payload.status,30),search=text(payload.search,160);if(status)query=query.eq("status",status);if(search)query=query.or(`title.ilike.%${search.replace(/[%_,()]/g,"")}%,summary.ilike.%${search.replace(/[%_,()]/g,"")}%`);
   const {data,error,count}=await query;if(error)throw error;return response(req,{items:data||[],total:count||0});
  }
  if(action==="documentation.detail"){
   requirePermission("documentation.read");const articleId=uuid(payload.articleId),adminClient=privileged();
    const [article,versions,links,modules,roles,attachments]=await Promise.all([adminClient.from("knowledge_articles").select("*,knowledge_categories(name,slug)").eq("id",articleId).single(),adminClient.from("knowledge_article_versions").select("id,version_number,title,summary,content,availability,visibility,change_summary,created_at").eq("article_id",articleId).order("version_number",{ascending:false}),adminClient.from("knowledge_article_links").select("linked_article_id,link_type,position").eq("article_id",articleId).order("position"),adminClient.from("knowledge_article_modules").select("module_key").eq("article_id",articleId).order("module_key"),adminClient.from("knowledge_article_roles").select("role_key").eq("article_id",articleId).order("role_key"),adminClient.from("knowledge_article_attachments").select("id,article_version,original_name,mime_type,size_bytes,created_at").eq("article_id",articleId).order("created_at",{ascending:false})]);
    const firstError=[article,versions,links,modules,roles,attachments].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{article:{...article.data,module_keys:(modules.data||[]).map(item=>item.module_key),role_keys:(roles.data||[]).map(item=>item.role_key)},versions:versions.data||[],links:links.data||[],attachments:attachments.data||[]});
  }
  if(action==="documentation.save"){
   requirePermission("documentation.write");const values=record(payload.values),articleId=payload.articleId?uuid(payload.articleId):null,adminClient=privileged(),reason=text(payload.reason,500)||"Mise à jour éditoriale";
    const categoryId=uuid(values.category_id),title=text(values.title,240),content=text(values.content,50_000),summary=text(values.summary,800),visibility=oneOf(values.visibility,["public","authenticated","company","internal"],"authenticated"),availability=oneOf(values.availability,["available","partial","configuration_required","external_connector_required","roadmap","unavailable"],"available"),language=text(values.language,10)||"fr",appVersionMin=text(values.app_version_min,30)||null,appVersionMax=text(values.app_version_max,30)||null;
    const moduleKeys=Array.from(new Set(text(values.module_keys,1000).split(",").map(value=>value.trim().toLowerCase()).filter(value=>/^[a-z0-9_:-]+$/.test(value)))).slice(0,50),roleKeys=Array.from(new Set(text(values.role_keys,1000).split(",").map(value=>value.trim().toLowerCase()).filter(value=>/^[a-z0-9_-]+$/.test(value)))).slice(0,20);
   if(title.length<4||content.length<20)throw new Error("Le titre et le contenu officiel sont obligatoires.");
   let oldState:Record<string,unknown>|null=null,nextVersion=1,saved;
    if(articleId){const existing=await adminClient.from("knowledge_articles").select("*").eq("id",articleId).single();if(existing.error)throw existing.error;oldState=existing.data;nextVersion=Number(existing.data.current_version||0)+1;const result=await adminClient.from("knowledge_articles").update({category_id:categoryId,slug:slug(values.slug||title),title,summary,content,visibility,availability,language,app_version_min:appVersionMin,app_version_max:appVersionMax,status:"draft",published_at:null,current_version:nextVersion,updated_by:context.user_id,updated_at:new Date().toISOString()}).eq("id",articleId).select().single();if(result.error)throw result.error;saved=result.data;}
    else{const result=await adminClient.from("knowledge_articles").insert({category_id:categoryId,slug:slug(values.slug||title),title,summary,content,visibility,availability,language,app_version_min:appVersionMin,app_version_max:appVersionMax,status:"draft",current_version:1,created_by:context.user_id,updated_by:context.user_id}).select().single();if(result.error)throw result.error;saved=result.data;}
    const version=await adminClient.from("knowledge_article_versions").insert({article_id:saved.id,version_number:nextVersion,title,summary,content,availability,visibility,change_summary:reason,created_by:context.user_id});if(version.error)throw version.error;
    const [removedModules,removedRoles]=await Promise.all([adminClient.from("knowledge_article_modules").delete().eq("article_id",saved.id),adminClient.from("knowledge_article_roles").delete().eq("article_id",saved.id)]);if(removedModules.error||removedRoles.error)throw removedModules.error||removedRoles.error;
    if(moduleKeys.length){const inserted=await adminClient.from("knowledge_article_modules").insert(moduleKeys.map(module_key=>({article_id:saved.id,module_key})));if(inserted.error)throw inserted.error;}
    if(roleKeys.length){const inserted=await adminClient.from("knowledge_article_roles").insert(roleKeys.map(role_key=>({article_id:saved.id,role_key})));if(inserted.error)throw inserted.error;}
   await audit(articleId?"documentation.article.update":"documentation.article.create","knowledge_article",saved.id,saved.company_id||null,oldState,saved,reason);return response(req,{article:saved},articleId?200:201);
  }
  if(action==="documentation.restore"){
   requirePermission("documentation.write");const articleId=uuid(payload.articleId),versionId=uuid(payload.versionId),adminClient=privileged();
   const [existing,source]=await Promise.all([adminClient.from("knowledge_articles").select("*").eq("id",articleId).single(),adminClient.from("knowledge_article_versions").select("*").eq("id",versionId).eq("article_id",articleId).single()]);if(existing.error||source.error)throw existing.error||source.error;
   const nextVersion=Number(existing.data.current_version||0)+1,now=new Date().toISOString(),reason=`Restauration de la version ${source.data.version_number}`;
   const restored=await adminClient.from("knowledge_articles").update({title:source.data.title,summary:source.data.summary,content:source.data.content,availability:source.data.availability,visibility:source.data.visibility,status:"draft",published_at:null,current_version:nextVersion,updated_by:context.user_id,updated_at:now}).eq("id",articleId).select().single();if(restored.error)throw restored.error;
   const version=await adminClient.from("knowledge_article_versions").insert({article_id:articleId,version_number:nextVersion,title:source.data.title,summary:source.data.summary,content:source.data.content,availability:source.data.availability,visibility:source.data.visibility,change_summary:reason,created_by:context.user_id});if(version.error)throw version.error;
   const removed=await adminClient.from("knowledge_article_chunks").delete().eq("article_id",articleId);if(removed.error)throw removed.error;
   await audit("documentation.article.restore","knowledge_article",articleId,restored.data.company_id||null,existing.data,restored.data,reason);return response(req,{article:restored.data},201);
  }
  if(action==="documentation.duplicate"){
   requirePermission("documentation.write");const articleId=uuid(payload.articleId),adminClient=privileged();
   const [source,modules,roles]=await Promise.all([adminClient.from("knowledge_articles").select("*").eq("id",articleId).single(),adminClient.from("knowledge_article_modules").select("module_key").eq("article_id",articleId),adminClient.from("knowledge_article_roles").select("role_key").eq("article_id",articleId)]);if(source.error||modules.error||roles.error)throw source.error||modules.error||roles.error;
   const title=`Copie de ${text(source.data.title,220)}`,copySlug=`${slug(source.data.slug||source.data.title)}-copie-${Date.now().toString(36)}`.slice(0,120),created=await adminClient.from("knowledge_articles").insert({category_id:source.data.category_id,slug:copySlug,title,summary:source.data.summary,content:source.data.content,status:"draft",visibility:source.data.visibility,availability:source.data.availability,company_id:source.data.company_id,language:source.data.language,current_version:1,app_version_min:source.data.app_version_min,app_version_max:source.data.app_version_max,created_by:context.user_id,updated_by:context.user_id}).select().single();if(created.error)throw created.error;
   const version=await adminClient.from("knowledge_article_versions").insert({article_id:created.data.id,version_number:1,title,summary:source.data.summary,content:source.data.content,availability:source.data.availability,visibility:source.data.visibility,change_summary:`Duplication de l’article ${source.data.title}`,created_by:context.user_id});if(version.error)throw version.error;
   if(modules.data?.length){const inserted=await adminClient.from("knowledge_article_modules").insert(modules.data.map(item=>({article_id:created.data.id,module_key:item.module_key})));if(inserted.error)throw inserted.error;}
   if(roles.data?.length){const inserted=await adminClient.from("knowledge_article_roles").insert(roles.data.map(item=>({article_id:created.data.id,role_key:item.role_key})));if(inserted.error)throw inserted.error;}
   await audit("documentation.article.duplicate","knowledge_article",created.data.id,created.data.company_id||null,null,created.data,`Duplication de ${articleId}`);return response(req,{article:created.data},201);
  }
  if(action==="documentation.attachment.upload"){
   requirePermission("documentation.write");const articleId=uuid(payload.articleId),adminClient=privileged(),fileName=safeFileName(payload.fileName),mimeType=text(payload.mimeType,160).toLowerCase(),size=Number(payload.size||0),encoded=String(payload.fileBase64||"");
   if(!knowledgeAttachmentTypes[mimeType]?.has(fileName.extension))throw new Error("Format de pièce jointe refusé ou extension incohérente.");if(!Number.isInteger(size)||size<1||size>10485760||encoded.length>13981020)throw new Error("La pièce jointe doit faire 10 Mo maximum.");
   const article=await adminClient.from("knowledge_articles").select("id,current_version,company_id").eq("id",articleId).single();if(article.error)throw article.error;const bytes=bytesFromBase64(encoded);if(bytes.byteLength!==size)throw new Error("La taille du fichier ne correspond pas à la demande.");
   const attachmentId=crypto.randomUUID(),path=`${articleId}/${article.data.current_version}/${attachmentId}/${fileName.storage}`,uploaded=await adminClient.storage.from("knowledge-article-attachments").upload(path,bytes,{contentType:mimeType,upsert:false});if(uploaded.error)throw uploaded.error;
   const inserted=await adminClient.from("knowledge_article_attachments").insert({id:attachmentId,article_id:articleId,article_version:article.data.current_version,storage_path:path,original_name:fileName.original,mime_type:mimeType,size_bytes:size,created_by:context.user_id}).select("id,article_version,original_name,mime_type,size_bytes,created_at").single();if(inserted.error){await adminClient.storage.from("knowledge-article-attachments").remove([path]);throw inserted.error;}
   await audit("documentation.article.attachment.upload","knowledge_article",articleId,article.data.company_id||null,null,{attachment_id:attachmentId,name:fileName.original,size},"Ajout d’une pièce jointe documentaire");return response(req,{attachment:inserted.data},201);
  }
  if(action==="documentation.attachment.download"){
   requirePermission("documentation.read");const attachmentId=uuid(payload.attachmentId),adminClient=privileged(),attachment=await adminClient.from("knowledge_article_attachments").select("id,article_id,storage_bucket,storage_path,original_name,mime_type,size_bytes").eq("id",attachmentId).single();if(attachment.error)throw attachment.error;const signed=await adminClient.storage.from(attachment.data.storage_bucket).createSignedUrl(attachment.data.storage_path,60,{download:attachment.data.original_name});if(signed.error||!signed.data?.signedUrl)throw signed.error||new Error("Lien de téléchargement indisponible.");await audit("documentation.article.attachment.download","knowledge_article",attachment.data.article_id,null,null,{attachment_id:attachmentId},"Téléchargement temporaire");return response(req,{url:signed.data.signedUrl,name:attachment.data.original_name,expiresIn:60});
  }
  if(action==="documentation.transition"){
   const targetStatus=oneOf(payload.status,["draft","review","published","archived"]);requirePermission(targetStatus==="published"?"documentation.publish":"documentation.write");const articleId=uuid(payload.articleId),adminClient=privileged(),existing=await adminClient.from("knowledge_articles").select("*").eq("id",articleId).single();if(existing.error)throw existing.error;
   if(targetStatus==="published"&&(!text(existing.data.content,50_000)||!existing.data.current_version))throw new Error("Une version complète est requise avant publication.");
   const now=new Date().toISOString(),changes:Record<string,unknown>={status:targetStatus,updated_by:context.user_id,updated_at:now};if(targetStatus==="published")Object.assign(changes,{published_at:now,archived_at:null,last_reviewed_at:now});if(targetStatus==="archived")changes.archived_at=now;
   const updated=await adminClient.from("knowledge_articles").update(changes).eq("id",articleId).select().single();if(updated.error)throw updated.error;
    if(targetStatus==="published"||targetStatus==="archived"){
     const queued=await adminClient.from("knowledge_index_events").insert({article_id:articleId,article_version:updated.data.current_version,event_type:targetStatus==="published"?"publish":"remove",status:"processing",created_by:context.user_id}).select("id").single();if(queued.error)throw queued.error;
     const removed=await adminClient.from("knowledge_article_chunks").delete().eq("article_id",articleId);if(removed.error)throw removed.error;
     if(targetStatus==="published"){
      const indexedText=`${text(updated.data.summary,800)}\n\n${text(updated.data.content,50_000)}`.trim();
      const indexed=await adminClient.from("knowledge_article_chunks").insert({article_id:articleId,article_version:updated.data.current_version,chunk_index:0,heading:text(updated.data.title,240),content:indexedText,token_count:Math.max(1,Math.ceil(indexedText.length/4))});if(indexed.error)throw indexed.error;
     }
     const completed=await adminClient.from("knowledge_index_events").update({status:"completed",detail:targetStatus==="published"?"Article publié et indexé immédiatement.":"Article archivé et retiré de l’index.",completed_at:now}).eq("id",queued.data.id);if(completed.error)throw completed.error;
    }
   await audit(`documentation.article.${targetStatus}`,"knowledge_article",articleId,updated.data.company_id||null,existing.data,updated.data,payload.reason);return response(req,{article:updated.data});
  }
  if(action==="documentation.unanswered"){
   requirePermission("documentation.read");const {data,error}=await privileged().from("knowledge_unanswered_questions").select("id,company_id,question,normalized_question,occurrences,status,linked_article_id,first_asked_at,last_asked_at").order("occurrences",{ascending:false}).order("last_asked_at",{ascending:false}).limit(500);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="documentation.index"){
   requirePermission("documentation.index");const {data,error}=await privileged().from("knowledge_index_events").select("id,article_id,article_version,event_type,status,detail,created_at,completed_at").order("created_at",{ascending:false}).limit(300);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="documentation.stats"){
   requirePermission("documentation.read");const adminClient=privileged(),[articles,searches,feedback,unanswered]=await Promise.all([adminClient.from("knowledge_articles").select("status"),adminClient.from("knowledge_search_events").select("id",{count:"exact",head:true}),adminClient.from("knowledge_article_feedback").select("helpful"),adminClient.from("knowledge_unanswered_questions").select("id",{count:"exact",head:true}).in("status",["open","reviewing"])]);const firstError=[articles,searches,feedback,unanswered].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{stats:{articles:articles.data||[],searches:searches.count||0,helpful:(feedback.data||[]).filter(item=>item.helpful).length,unhelpful:(feedback.data||[]).filter(item=>!item.helpful).length,unanswered:unanswered.count||0}});
  }
  if(action==="support.v2.list"){
   requirePermission("support.queue");const adminClient=privileged(),page=integer(payload.page,1,1,1_000_000),pageSize=integer(payload.pageSize,100,1,200);let query=adminClient.from("support_tickets").select("id,ticket_number,company_id,requester_user_id,requester_email,subject,category,module_key,ticket_type,priority,status,source,assigned_team_id,assigned_admin_id,first_response_at,resolved_at,last_client_message_at,last_support_message_at,created_at,updated_at,companies(name)",{count:"exact"}).order("updated_at",{ascending:false}).range((page-1)*pageSize,page*pageSize-1);const status=text(payload.status,40),priority=text(payload.priority,20),mine=Boolean(payload.mine);if(status)query=query.eq("status",status);if(priority)query=query.eq("priority",priority);if(mine)query=query.eq("assigned_admin_id",context.id);const {data,error,count}=await query;if(error)throw error;return response(req,{items:data||[],total:count||0});
  }
  if(action==="support.v2.detail"){
   requirePermission("support.queue");const ticketId=uuid(payload.ticketId),adminClient=privileged();const [ticket,messages,events,attachments,teams,admins]=await Promise.all([adminClient.from("support_tickets").select("*,companies(name)").eq("id",ticketId).single(),adminClient.from("support_ticket_messages").select("id,author_user_id,author_admin_id,author_kind,visibility,body,sent_at,edited_at,created_at").eq("ticket_id",ticketId).order("created_at"),adminClient.from("support_ticket_events").select("id,event_type,public_summary,internal_detail,created_at,actor_user_id,actor_admin_id").eq("ticket_id",ticketId).order("created_at"),adminClient.from("support_ticket_attachments").select("id,original_name,mime_type,size_bytes,visibility,created_at").eq("ticket_id",ticketId).order("created_at"),adminClient.from("support_teams").select("id,name,active").eq("active",true).order("name"),adminClient.from("platform_admins").select("id,first_name,last_name,email,status").eq("status","active").order("first_name")]);const firstError=[ticket,messages,events,attachments,teams,admins].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{ticket:ticket.data,messages:messages.data||[],events:events.data||[],attachments:attachments.data||[],teams:teams.data||[],admins:admins.data||[]});
  }
  if(action==="support.v2.update"){
   requirePermission("support.assign");const ticketId=uuid(payload.ticketId),adminClient=privileged(),existing=await adminClient.from("support_tickets").select("*").eq("id",ticketId).single();if(existing.error)throw existing.error;const values=record(payload.values),changes:Record<string,unknown>={updated_at:new Date().toISOString()};if(values.status!==undefined)changes.status=oneOf(values.status,["new","to_qualify","in_progress","waiting_customer","waiting_internal","resolved","closed","cancelled"]);if(values.priority!==undefined)changes.priority=oneOf(values.priority,["low","normal","high","urgent"]);if(values.assigned_team_id!==undefined)changes.assigned_team_id=values.assigned_team_id?uuid(values.assigned_team_id):null;if(values.assigned_admin_id!==undefined)changes.assigned_admin_id=values.assigned_admin_id?uuid(values.assigned_admin_id):null;if(changes.status==="resolved")changes.resolved_at=new Date().toISOString();if(changes.status==="closed")changes.closed_at=new Date().toISOString();const updated=await adminClient.from("support_tickets").update(changes).eq("id",ticketId).select().single();if(updated.error)throw updated.error;await adminClient.from("support_ticket_events").insert({ticket_id:ticketId,company_id:updated.data.company_id,actor_admin_id:context.id,event_type:"support_update",public_summary:changes.status?`Statut : ${changes.status}`:null,internal_detail:{changes,reason:text(payload.reason,500)}});await audit("support.ticket.update","support_ticket",ticketId,updated.data.company_id,existing.data,updated.data,payload.reason);return response(req,{ticket:updated.data});
  }
  if(action==="support.v2.attachment"){
   requirePermission("support.queue");const attachmentId=uuid(payload.attachmentId),adminClient=privileged();const {data:attachment,error}=await adminClient.from("support_ticket_attachments").select("id,ticket_id,storage_path,original_name,mime_type,size_bytes,visibility").eq("id",attachmentId).single();if(error)throw error;const {data:signed,error:signedError}=await adminClient.storage.from("support-ticket-attachments").createSignedUrl(attachment.storage_path,60,{download:attachment.original_name});if(signedError||!signed?.signedUrl)throw signedError||new Error("Lien de téléchargement indisponible.");await audit("support.ticket.attachment.download","support_ticket",attachment.ticket_id,null,null,{attachment_id:attachment.id,visibility:attachment.visibility});return response(req,{url:signed.signedUrl,name:attachment.original_name,expiresIn:60});
  }
  if(action==="support.v2.message"){
   const visibility=oneOf(payload.visibility,["client","internal","draft"],"draft");requirePermission(visibility==="client"?"support.reply":"support.internal");const ticketId=uuid(payload.ticketId),bodyText=text(payload.body,12_000);if(!bodyText)throw new Error("Le message est vide.");const adminClient=privileged(),ticket=await adminClient.from("support_tickets").select("*").eq("id",ticketId).single();if(ticket.error)throw ticket.error;const sentAt=visibility==="draft"?null:new Date().toISOString(),created=await adminClient.from("support_ticket_messages").insert({ticket_id:ticketId,author_admin_id:context.id,author_kind:"support",visibility,body:bodyText,sent_at:sentAt}).select().single();if(created.error)throw created.error;if(visibility==="client"){const now=new Date().toISOString(),updated=await adminClient.from("support_tickets").update({status:payload.status?oneOf(payload.status,["in_progress","waiting_customer","resolved"],"in_progress"):"waiting_customer",first_response_at:ticket.data.first_response_at||now,last_support_message_at:now,updated_at:now}).eq("id",ticketId);if(updated.error)throw updated.error;}if(visibility!=="draft")await adminClient.from("support_ticket_events").insert({ticket_id:ticketId,company_id:ticket.data.company_id,actor_admin_id:context.id,event_type:visibility==="client"?"support_message":"internal_note",public_summary:visibility==="client"?"Réponse du support Piloz":null,internal_detail:visibility==="internal"?{message_id:created.data.id}:null});await audit(`support.ticket.message.${visibility}`,"support_ticket",ticketId,ticket.data.company_id,null,{message_id:created.data.id,visibility},payload.reason);return response(req,{message:created.data},201);
  }
  if(action==="support.saved_replies"){
   requirePermission("support.queue");const {data,error}=await privileged().from("support_saved_replies").select("id,title,body,category,active,created_at,updated_at").eq("active",true).order("title");if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="support.settings"){
   requirePermission("support.settings");const adminClient=privileged(),[teams,policies,replies]=await Promise.all([adminClient.from("support_teams").select("*").order("name"),adminClient.from("support_sla_policies").select("*").order("priority"),adminClient.from("support_saved_replies").select("*").order("title")]);const firstError=[teams,policies,replies].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{teams:teams.data||[],policies:policies.data||[],replies:replies.data||[]});
  }
  if(action==="suggestions.list"){
   requirePermission("suggestions.read");const {data,error}=await privileged().from("product_suggestions").select("id,suggestion_number,company_id,title,description,module_key,status,priority,source_ticket_id,created_at,updated_at,companies(name)").order("updated_at",{ascending:false}).limit(500);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="suggestions.update"){
   requirePermission("suggestions.write");const suggestionId=uuid(payload.suggestionId),adminClient=privileged(),existing=await adminClient.from("product_suggestions").select("*").eq("id",suggestionId).single();if(existing.error)throw existing.error;const status=oneOf(payload.status,["received","reviewing","planned","roadmap","rejected","delivered"]),updated=await adminClient.from("product_suggestions").update({status,updated_at:new Date().toISOString()}).eq("id",suggestionId).select().single();if(updated.error)throw updated.error;await adminClient.from("product_suggestion_events").insert({suggestion_id:suggestionId,actor_admin_id:context.id,event_type:"status_changed",public_summary:`Statut : ${status}`,internal_detail:{reason:text(payload.reason,500)}});await audit("product.suggestion.update","product_suggestion",suggestionId,existing.data.company_id,existing.data,updated.data,payload.reason);return response(req,{suggestion:updated.data});
  }
  if(action==="system.summary"){
   requirePermission("system.read");const [events,notifications]=await Promise.all([
    client.from("platform_system_events").select("id,event_type,severity,status,source,summary,retry_count,occurred_at,resolved_at").order("occurred_at",{ascending:false}).limit(100),
    client.from("platform_notifications").select("id,event_type,severity,title,message,company_id,action_url,created_at").order("created_at",{ascending:false}).limit(100)
   ]);const firstError=[events,notifications].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{events:events.data||[],notifications:notifications.data||[],schemaVersion:"202607240055",adminVersion:"0.1.1"});
  }
  if(action==="compliance.summary"){
   requirePermission("compliance.read");const [configurations,anomalies,privacy]=await Promise.all([
    client.from("company_fiscal_configurations").select("company_id,mode,activation_status,application_version,schema_version,signing_status,updated_at").order("updated_at",{ascending:false}).limit(5000),
    client.from("compliance_anomalies").select("id,company_id,anomaly_type,severity,source,detected_at,application_version,schema_version").order("detected_at",{ascending:false}).limit(500),
    permissions.has("privacy.read")?client.from("data_subject_requests").select("id,company_id,request_type,subject_kind,received_at,identity_verified_at,due_at,status,closed_at").order("received_at",{ascending:false}).limit(500):Promise.resolve({data:[],error:null})
   ]);const firstError=[configurations,anomalies,privacy].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{configurations:configurations.data||[],anomalies:anomalies.data||[],privacy:privacy.data||[]});
  }
  if(action==="subscriptions.change"){
   requirePermission("subscriptions.write");const {data,error}=await client.rpc("platform_admin_change_subscription",{
    target_company_id:uuid(payload.companyId),target_plan_version_id:uuid(payload.planVersionId),target_billing_interval:text(payload.billingInterval,20),
    effective_mode:text(payload.effectiveMode,20),target_discount_type:text(payload.discountType,20)||null,
    target_discount_value:payload.discountValue===null||payload.discountValue===undefined?null:Number(payload.discountValue),
    target_discount_ends_at:text(payload.discountEndsAt,40)||null,target_reason:text(payload.reason,500),target_note:text(payload.note,1000)||null
   });if(error)throw error;return response(req,{subscription:data});
  }
  if(action==="subscriptions.manage"){
   requirePermission("subscriptions.write");const {data,error}=await client.rpc("platform_admin_manage_subscription",{target_company_id:uuid(payload.companyId),target_operation:text(payload.operation,40),target_parameters:record(payload.parameters),target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{subscription:data});
  }
  if(action==="features.override"){
   requirePermission("subscriptions.write");const {data,error}=await client.rpc("platform_admin_set_feature_override",{target_company_id:uuid(payload.companyId),target_feature_key:text(payload.featureKey,100),target_enabled:Boolean(payload.enabled),target_ends_at:text(payload.endsAt,40)||null,target_reason:text(payload.reason,500)});if(error)throw error;return response(req,{override:data},201);
  }
  if(action==="profile.update"){
   const {data,error}=await client.rpc("platform_admin_update_profile",{target_values:record(payload.values)});if(error)throw error;return response(req,{admin:data});
  }
  if(action==="admins.list"){
   requirePermission("admin.read");const {data,error}=await client.from("platform_admins").select("id,user_id,role,status,first_name,last_name,email,mfa_required,last_login_at,last_activity_at,created_at").order("created_at",{ascending:false});if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="admins.invite"){
   requirePermission("admin.write");const targetEmail=email(payload.email),firstName=text(payload.firstName,100),lastName=text(payload.lastName,100),role=text(payload.role,40),reason=text(payload.reason,500);
   const {data:invitation,error:inviteError}=await privileged().auth.admin.inviteUserByEmail(targetEmail,{data:{first_name:firstName,last_name:lastName},redirectTo:"https://admin.piloz.fr"});if(inviteError||!invitation.user)throw Object.assign(new Error("L’invitation administrateur n’a pas pu être créée."),{status:inviteError?.status||400});
   const {data,error}=await client.rpc("platform_admin_add_administrator",{target_user_id:invitation.user.id,target_email:targetEmail,target_role:role,target_first_name:firstName,target_last_name:lastName,target_reason:reason});if(error)throw error;return response(req,{admin:data,invitationSent:true,message:"Invitation envoyée. Si elle n’apparaît pas dans quelques minutes, vérifiez les courriers indésirables (spams)."},201);
  }
  if(action==="notifications.list"){
   requirePermission("notifications.read");const {data,error}=await client.from("platform_notifications").select("id,event_type,severity,title,message,company_id,action_url,read_by,created_at,expires_at").or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`).order("created_at",{ascending:false}).limit(50);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="trials.list"){
   requirePermission("subscriptions.read");const {data,error}=await client.from("subscriptions").select("company_id,plan_key,status,trial_started_at,trial_ends_at,created_at,updated_at,companies(name,platform_status),subscription_plan_versions(name)").eq("status","trialing").order("trial_ends_at",{ascending:true}).limit(100);if(error)throw error;return response(req,{items:data||[]});
  }
  if(action==="global.search"){
   const query=text(payload.search,160);if(query.length<2)return response(req,{companies:[],users:[]});
   const [companies,users]=await Promise.all([
    permissions.has("companies.read")?client.rpc("platform_admin_list_companies",{search_text:query,status_filter:null,plan_filter:null,page_number:1,page_size:6}):Promise.resolve({data:[],error:null}),
    permissions.has("users.read")?client.rpc("platform_admin_list_users",{search_text:query,target_company_id:null,page_number:1,page_size:6}):Promise.resolve({data:[],error:null})
   ]);const firstError=[companies,users].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{companies:companies.data||[],users:users.data||[]});
  }
  if(action==="companies.suspension"){
   requirePermission("companies.suspend");const {data,error}=await client.rpc("platform_admin_set_company_suspension",{
    target_company_id:uuid(payload.companyId),target_suspended:Boolean(payload.suspended),target_level:text(payload.level,30)||"full",target_reason:text(payload.reason,500)
   });if(error)throw error;return response(req,{company:data});
  }
  if(action==="support.start"){
   requirePermission("support.session");const {data,error}=await client.rpc("platform_admin_start_support_session",{
    target_company_id:uuid(payload.companyId),target_reason:text(payload.reason,500),target_mode:text(payload.mode,30)||"read_only"
   });if(error)throw error;return response(req,{session:data});
  }
  if(action==="support.end"){
   requirePermission("support.session");const {data,error}=await client.rpc("platform_admin_end_support_session",{target_session_id:uuid(payload.sessionId)});if(error)throw error;return response(req,{session:data});
  }
  return response(req,{error:"Action inconnue"},404);
 }catch(error){
  const status=Number((error as {status?:number})?.status)||((error as {code?:string})?.code==="42501"?403:400);
  console.error("[PILOZ Admin API] request rejected",{action,status,code:(error as {code?:string})?.code||"request_failed",userId:user.id});
  return response(req,{error:(error as Error)?.message||"Opération impossible",code:(error as {code?:string})?.code||"request_failed"},status);
 }
});
