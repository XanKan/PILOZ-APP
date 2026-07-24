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
 try{
  if(action==="context"){await client.rpc("platform_admin_register_session",{target_user_agent:text(req.headers.get("user-agent"),500)||null});return response(req,{context});}
  const {data:sessionActive,error:sessionError}=await client.rpc("platform_admin_validate_and_touch_session");
  if(sessionError||!sessionActive)return response(req,{error:"Session administrateur expirée ou révoquée",code:"admin_session_expired"},401);
  if(action==="dashboard"){
   requirePermission("companies.read");const {data,error}=await client.rpc("platform_admin_dashboard");if(error)throw error;return response(req,{dashboard:data});
  }
  if(action==="companies.list"){
   requirePermission("companies.read");const {data,error}=await client.rpc("platform_admin_list_companies",{
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
   const ownerEmail=email(companyValues.owner_email),ownerUserId=payload.ownerUserId?uuid(payload.ownerUserId):null;let userId=ownerUserId;
   if(!userId){const {data,error}=await privileged().auth.admin.inviteUserByEmail(ownerEmail,{data:{first_name:text(companyValues.owner_first_name,100),last_name:text(companyValues.owner_last_name,100)},redirectTo:"https://app.piloz.fr"});if(error||!data.user)throw Object.assign(new Error(error?.message?.toLowerCase().includes("already")?"Ce propriétaire existe déjà. Ajoutez-le depuis sa fiche utilisateur.":"L’invitation du propriétaire a échoué."),{status:error?.status||400});userId=data.user.id;}
   const {data,error}=await client.rpc("platform_admin_create_company",{target_owner_user_id:userId,target_company:companyValues,target_subscription:subscriptionValues,target_reason:text(payload.reason,500)});if(error)throw error;
   return response(req,{company:data,ownerUserId:userId,invitationSent:!ownerUserId},201);
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
   const {data:invitation,error:inviteError}=await privileged().auth.admin.inviteUserByEmail(targetEmail,{data:{first_name:text(payload.firstName,100),last_name:text(payload.lastName,100)},redirectTo:"https://app.piloz.fr"});
   if(inviteError||!invitation.user)throw Object.assign(new Error(inviteError?.message?.toLowerCase().includes("already")?"Cet utilisateur existe déjà. Utilisez son identifiant pour le rattacher.":"L’invitation n’a pas pu être envoyée."),{status:inviteError?.status||400});
   const reason=text(payload.reason,500)||"Invitation par un administrateur Piloz";
   const {error:memberError}=await client.rpc("platform_admin_manage_company_user",{target_company_id:companyId,target_user_id:invitation.user.id,target_role:role,target_operation:"attach",target_reason:reason});if(memberError)throw memberError;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:invitation.user.id,target_company_id:companyId,target_action:"user.invite",target_reason:reason,target_new_state:{email:targetEmail,role}});
   return response(req,{userId:invitation.user.id,invitationSent:true},201);
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
  if(action==="users.password_reset"){
   requirePermission("users.write");const targetEmail=email(payload.email),userId=uuid(payload.userId),companyId=payload.companyId?uuid(payload.companyId):null,reason=text(payload.reason,500);
   if(!reason)throw new Error("Le motif est obligatoire");const {error}=await privileged().auth.resetPasswordForEmail(targetEmail,{redirectTo:"https://app.piloz.fr"});if(error)throw error;
   await client.rpc("platform_admin_record_auth_action",{target_user_id:userId,target_company_id:companyId,target_action:"user.password_reset_requested",target_reason:reason,target_new_state:{requested:true}});
   return response(req,{sent:true});
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
  if(action==="system.summary"){
   requirePermission("system.read");const [events,notifications]=await Promise.all([
    client.from("platform_system_events").select("id,event_type,severity,status,source,summary,retry_count,occurred_at,resolved_at").order("occurred_at",{ascending:false}).limit(100),
    client.from("platform_notifications").select("id,event_type,severity,title,message,company_id,action_url,created_at").order("created_at",{ascending:false}).limit(100)
   ]);const firstError=[events,notifications].find(result=>result.error)?.error;if(firstError)throw firstError;return response(req,{events:events.data||[],notifications:notifications.data||[],schemaVersion:"202607240053",adminVersion:"0.1.0"});
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
   const {data,error}=await client.rpc("platform_admin_add_administrator",{target_user_id:invitation.user.id,target_email:targetEmail,target_role:role,target_first_name:firstName,target_last_name:lastName,target_reason:reason});if(error)throw error;return response(req,{admin:data,invitationSent:true},201);
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
