import { createClient } from "npm:@supabase/supabase-js@2";

type Payload=Record<string,unknown>;
const origins=new Set(["https://app.piloz.fr","http://localhost:4173","http://localhost:5173","http://127.0.0.1:4173","http://127.0.0.1:5173"]);
function cors(req:Request){const origin=req.headers.get("origin")||"";return{
  "Access-Control-Allow-Origin":origins.has(origin)?origin:"https://app.piloz.fr",
  "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type, x-request-id",
  "Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"
};}
function reply(req:Request,value:unknown,status=200){return new Response(JSON.stringify(value),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function clean(value:unknown,max=200){return String(value??"").trim().replace(/\s+/g," ").slice(0,max);}
function email(value:unknown){const result=clean(value,254).toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(result))throw new Error("Adresse e-mail invalide.");return result;}
function uuid(value:unknown,optional=false){const result=clean(value,40);if(optional&&!result)return null;if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result))throw new Error("Identifiant invalide.");return result;}
async function sha256(value:string){const bytes=new TextEncoder().encode(value),hash=await crypto.subtle.digest("SHA-256",bytes);return Array.from(new Uint8Array(hash)).map(byte=>byte.toString(16).padStart(2,"0")).join("");}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
  if(req.method!=="POST")return reply(req,{error:"Méthode non autorisée."},405);
  const origin=req.headers.get("origin")||"";if(origin&&!origins.has(origin))return reply(req,{error:"Origine non autorisée."},403);
  const authorization=req.headers.get("authorization")||"";if(!authorization.startsWith("Bearer "))return reply(req,{error:"Authentification requise."},401);
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!serviceKey)return reply(req,{error:"Le service d’invitation n’est pas configuré."},503);
  const userClient=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:userError}=await userClient.auth.getUser();if(userError||!user)return reply(req,{error:"Session invalide."},401);
  let body:{action?:unknown;payload?:Payload};try{body=await req.json();}catch{return reply(req,{error:"Requête invalide."},400);}
  const action=clean(body.action,40),payload=body.payload||{},companyId=uuid(payload.companyId) as string;
  const {data:canManage,error:permissionError}=await userClient.rpc("has_company_permission",{target_company_id:companyId,target_permission:"company.users.manage"});
  if(permissionError||canManage!==true)return reply(req,{error:"Vous n’avez pas l’autorisation de gérer les utilisateurs."},403);

  const audit=async(actionName:string,targetType:string,targetId:string|null,previous:unknown,next:unknown,reason:string|null=null)=>{
    const {error}=await admin.from("company_access_audit").insert({company_id:companyId,actor_user_id:user.id,action:actionName,target_type:targetType,target_id:targetId,previous_state:previous,new_state:next,reason,request_id:req.headers.get("x-request-id"),user_agent:clean(req.headers.get("user-agent"),500)||null});
    if(error)console.error("[company-access] audit",{code:error.code,message:error.message});
  };
  try{
    if(action==="invite"){
      const firstName=clean(payload.firstName,100),lastName=clean(payload.lastName,100),targetEmail=email(payload.email),roleId=uuid(payload.roleId) as string,teamId=uuid(payload.teamId,true);
      if(!firstName||!lastName)throw new Error("Le prénom et le nom sont obligatoires.");
      const {data:role,error:roleError}=await admin.from("company_roles").select("id,name,active").eq("id",roleId).eq("company_id",companyId).maybeSingle();
      if(roleError||!role?.active)throw new Error("Le rôle sélectionné n’est plus disponible.");
      if(teamId){const {data:team}=await admin.from("company_teams").select("id").eq("id",teamId).eq("company_id",companyId).eq("active",true).maybeSingle();if(!team)throw new Error("L’équipe sélectionnée n’est plus disponible.");}
      const [{count:activeCount},{data:subscription},{data:pending},{data:members}]=await Promise.all([
        admin.from("company_members").select("user_id",{count:"exact",head:true}).eq("company_id",companyId).in("platform_status",["pending","active","suspended"]),
        admin.from("subscriptions").select("plan_key,max_users_override").eq("company_id",companyId).maybeSingle(),
        admin.from("company_invitations").select("id").eq("company_id",companyId).eq("email",targetEmail).in("status",["pending","sent"]).limit(1),
        admin.from("company_members").select("user_id").eq("company_id",companyId).neq("platform_status","removed")
      ]);
      if(pending?.length)throw new Error("Une invitation est déjà en attente pour cette adresse e-mail.");
      const {data:plan}=subscription?.plan_key?await admin.from("plans").select("max_users").eq("key",subscription.plan_key).maybeSingle():{data:null};
      const maxUsers=Number(subscription?.max_users_override||plan?.max_users||1);if(Number(activeCount||0)>=maxUsers)throw new Error(`Votre offre autorise ${maxUsers} utilisateur${maxUsers>1?"s":""}. Modifiez l’abonnement avant d’ajouter un membre.`);
      let existingUser:null|{id:string;email?:string}=null;
      for(let page=1;page<=20&&!existingUser;page++){const {data,error}=await admin.auth.admin.listUsers({page,perPage:1000});if(error)throw error;existingUser=(data.users.find(candidate=>candidate.email?.toLowerCase()===targetEmail) as typeof existingUser)||null;if(data.users.length<1000)break;}
      if(existingUser&&members?.some(member=>member.user_id===existingUser!.id))throw new Error("Cet utilisateur appartient déjà à l’entreprise.");
      let invitedUserId=existingUser?.id||null,deliveryStatus="not_configured",invitationSent=false,deliveryError:string|null=null;
      if(!existingUser){
        const {data,error}=await admin.auth.admin.inviteUserByEmail(targetEmail,{data:{first_name:firstName,last_name:lastName,full_name:`${firstName} ${lastName}`},redirectTo:"https://app.piloz.fr/?mode=login"});
        if(error||!data.user){deliveryStatus="failed";deliveryError=error?.message||"Invitation Auth impossible";}else{invitedUserId=data.user.id;deliveryStatus="sent";invitationSent=true;}
      }
      const token=crypto.randomUUID()+crypto.randomUUID(),tokenHash=await sha256(token),status=deliveryStatus==="sent"?"sent":"pending";
      const {data:invitation,error:insertError}=await admin.from("company_invitations").insert({company_id:companyId,email:targetEmail,first_name:firstName,last_name:lastName,intended_role_id:roleId,intended_team_id:teamId,invited_user_id:invitedUserId,token_hash:tokenHash,status,delivery_status:deliveryStatus,send_count:invitationSent?1:0,last_sent_at:invitationSent?new Date().toISOString():null,delivery_error:deliveryError,invited_by:user.id}).select("id,status,delivery_status,expires_at").single();
      if(insertError)throw insertError;
      if(!existingUser&&invitedUserId){await admin.from("company_members").upsert({company_id:companyId,user_id:invitedUserId,role:"member",role_id:roleId,primary_team_id:teamId,platform_status:"pending"},{onConflict:"company_id,user_id"});}
      await audit("invitation.created","company_invitation",invitation.id,null,{email:targetEmail,role_id:roleId,team_id:teamId,status,delivery_status:deliveryStatus});
      return reply(req,{invitation,invitationSent,existingUser:Boolean(existingUser),message:invitationSent?"Invitation envoyée. Si elle n’apparaît pas dans quelques minutes, vérifiez les courriers indésirables (spams).":existingUser?"Invitation créée. L’utilisateur existant la rejoindra lors de sa prochaine connexion.":"Invitation créée, mais l’envoi automatique a échoué.",deliveryError},201);
    }
    if(action==="resend"){
      const invitationId=uuid(payload.invitationId) as string,{data:invitation}=await admin.from("company_invitations").select("*").eq("id",invitationId).eq("company_id",companyId).maybeSingle();
      if(!invitation||!["pending","sent","failed","expired"].includes(invitation.status))throw new Error("Cette invitation ne peut plus être renvoyée.");
      let sent=false,errorText:null|string=null;
      if(!invitation.invited_user_id){const result=await admin.auth.admin.inviteUserByEmail(invitation.email,{data:{first_name:invitation.first_name,last_name:invitation.last_name},redirectTo:"https://app.piloz.fr/?mode=login"});sent=!result.error;if(result.data.user)invitation.invited_user_id=result.data.user.id;errorText=result.error?.message||null;}
      else errorText="Le compte existe déjà : l’invitation sera proposée à sa prochaine connexion.";
      const next={status:sent?"sent":"pending",delivery_status:sent?"sent":"not_configured",delivery_error:errorText,send_count:Number(invitation.send_count||0)+(sent?1:0),last_sent_at:sent?new Date().toISOString():invitation.last_sent_at,expires_at:new Date(Date.now()+7*86400000).toISOString(),invited_user_id:invitation.invited_user_id,updated_at:new Date().toISOString()};
      await admin.from("company_invitations").update(next).eq("id",invitationId);await audit("invitation.resent","company_invitation",invitationId,{status:invitation.status},{status:next.status,delivery_status:next.delivery_status});
      return reply(req,{sent,message:sent?"Invitation renvoyée. Si elle n’apparaît pas dans quelques minutes, vérifiez les courriers indésirables (spams).":errorText});
    }
    if(action==="revoke_invitation"){
      const invitationId=uuid(payload.invitationId) as string,{data:before}=await admin.from("company_invitations").select("status").eq("id",invitationId).eq("company_id",companyId).maybeSingle();if(!before)throw new Error("Invitation introuvable.");
      await admin.from("company_invitations").update({status:"revoked",token_hash:null,revoked_at:new Date().toISOString(),revoked_by:user.id,updated_at:new Date().toISOString()}).eq("id",invitationId).eq("company_id",companyId);
      await audit("invitation.revoked","company_invitation",invitationId,before,{status:"revoked"},clean(payload.reason,500)||null);return reply(req,{revoked:true});
    }
    if(action==="update_invitation"){
      const invitationId=uuid(payload.invitationId) as string,roleId=uuid(payload.roleId) as string,teamId=uuid(payload.teamId,true);
      const [{data:before},{data:role},{data:team}]=await Promise.all([
        admin.from("company_invitations").select("id,status,intended_role_id,intended_team_id").eq("id",invitationId).eq("company_id",companyId).maybeSingle(),
        admin.from("company_roles").select("id,active").eq("id",roleId).eq("company_id",companyId).maybeSingle(),
        teamId?admin.from("company_teams").select("id,active").eq("id",teamId).eq("company_id",companyId).maybeSingle():Promise.resolve({data:null})
      ]);
      if(!before||!["pending","sent","failed","expired"].includes(before.status))throw new Error("Cette invitation ne peut plus être modifiée.");
      if(!role?.active)throw new Error("Le rôle sélectionné n’est plus disponible.");
      if(teamId&&!team?.active)throw new Error("L’équipe sélectionnée n’est plus disponible.");
      const next={intended_role_id:roleId,intended_team_id:teamId,updated_at:new Date().toISOString()};
      const {error}=await admin.from("company_invitations").update(next).eq("id",invitationId).eq("company_id",companyId);if(error)throw error;
      await audit("invitation.assignment_changed","company_invitation",invitationId,{role_id:before.intended_role_id,team_id:before.intended_team_id},{role_id:roleId,team_id:teamId});
      return reply(req,{updated:true});
    }
    if(action==="revoke_sessions"){
      const userId=uuid(payload.userId) as string,reason=clean(payload.reason,500);if(!reason)throw new Error("Le motif est obligatoire.");
      const response=await fetch(`${url}/auth/v1/admin/users/${userId}/logout`,{method:"POST",headers:{Authorization:`Bearer ${serviceKey}`,apikey:serviceKey}});if(!response.ok)throw new Error("Les sessions n’ont pas pu être révoquées.");
      await audit("member.sessions_revoked","company_member",userId,null,{revoked:true},reason);return reply(req,{revoked:true});
    }
    return reply(req,{error:"Action inconnue."},400);
  }catch(error){const value=error as {message?:string;status?:number;code?:string};console.error("[company-access]",{action,code:value.code||"",message:value.message||String(error)});return reply(req,{error:value.message||"Opération impossible.",code:value.code||""},Number(value.status)||400);}
});
