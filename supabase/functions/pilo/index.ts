import {createClient} from "npm:@supabase/supabase-js@2";
import {DisabledEmbeddingProvider,OpenAIResponsesAssistantProvider,ResilientAssistantProvider,SupabaseDocumentationSearchProvider} from "../_shared/pilo-providers.ts";

const origins=new Set(["https://app.piloz.fr","http://localhost:4173","http://localhost:5173","http://127.0.0.1:4173","http://127.0.0.1:5173"]);
const allowedMimes=new Set(["application/pdf","image/png","image/jpeg","image/webp","text/plain","text/csv","application/vnd.openxmlformats-officedocument.wordprocessingml.document","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]);
const allowedExtensions:Record<string,Set<string>>={
  "application/pdf":new Set(["pdf"]),"image/png":new Set(["png"]),"image/jpeg":new Set(["jpg","jpeg"]),"image/webp":new Set(["webp"]),
  "text/plain":new Set(["txt"]),"text/csv":new Set(["csv"]),
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document":new Set(["docx"]),
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":new Set(["xlsx"])
};
function cors(req:Request){const origin=req.headers.get("origin")||"";return{"Access-Control-Allow-Origin":origins.has(origin)?origin:"https://app.piloz.fr","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type, x-request-id","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Cache-Control":"no-store"};}
function reply(req:Request,value:unknown,status=200){return new Response(JSON.stringify(value),{status,headers:{...cors(req),"Content-Type":"application/json; charset=utf-8"}});}
function clean(value:unknown,max=2000){return String(value??"").trim().replace(/\s+/g," ").slice(0,max);}
function uuid(value:unknown){const result=clean(value,40);if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result))throw new Error("Identifiant invalide.");return result;}
function safeName(value:unknown){const original=clean(value,240),parts=original.split("."),extension=(parts.length>1?parts.pop():"bin")!.toLowerCase().replace(/[^a-z0-9]/g,"").slice(0,10)||"bin",base=parts.join(".").normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-zA-Z0-9_-]/g,"-").replace(/-+/g,"-").slice(0,80)||"fichier";return{original,storage:`${base}.${extension}`};}
function bytesFromBase64(value:string){const binary=atob(value),bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);return bytes;}
function isStockQuestion(question:string){const normalized=question.normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase();return/(^|\W)(stock|stocks|inventaire|inventaires)(\W|$)/.test(normalized);}
async function privacySafeIdentifier(userId:string,companyId:string){const bytes=new TextEncoder().encode(`${userId}:${companyId}:pilo`),digest=await crypto.subtle.digest("SHA-256",bytes);return`pilo_${Array.from(new Uint8Array(digest)).slice(0,16).map(value=>value.toString(16).padStart(2,"0")).join("")}`;}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
  if(req.method!=="POST")return reply(req,{error:"Méthode non autorisée."},405);
  const origin=req.headers.get("origin")||"";if(origin&&!origins.has(origin))return reply(req,{error:"Origine non autorisée."},403);
  const authorization=req.headers.get("authorization")||"";if(!authorization.startsWith("Bearer "))return reply(req,{error:"Authentification requise."},401);
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!serviceKey)return reply(req,{error:"Pilo n’est pas configuré sur le serveur."},503);
  const userClient=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}}),admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:userError}=await userClient.auth.getUser();if(userError||!user)return reply(req,{error:"Session invalide."},401);
  let body:any;try{body=await req.json();}catch{return reply(req,{error:"Requête invalide."},400);}
  try{
    const action=clean(body.action,60),companyId=uuid(body.companyId);
    const {data:isMember,error:memberError}=await userClient.rpc("is_company_member",{target_company_id:companyId});if(memberError||isMember!==true)return reply(req,{error:"Entreprise inaccessible."},403);
    if(action==="ask"){
      const question=clean(body.question,2000);if(question.length<2)return reply(req,{error:"La question est trop courte."},400);
      const {data:canAsk}=await userClient.rpc("has_company_permission",{target_company_id:companyId,target_permission:"help.assistant.use"});if(canAsk!==true)return reply(req,{error:"Vous n’avez pas accès à Pilo."},403);
      const {data:safe,error:safeError}=await userClient.rpc("sanitize_assistant_context",{input_context:body.safeContext||{}});if(safeError)throw safeError;
      const requestedConversationId=clean(body.conversationId,40);
      let conversation:any=null;
      if(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestedConversationId)){
        const {data}=await admin.from("assistant_conversations").select("id,company_id,user_id,status").eq("id",requestedConversationId).eq("company_id",companyId).eq("user_id",user.id).eq("status","open").maybeSingle();
        conversation=data||null;
      }
      if(!conversation){
        const {data,error}=await admin.from("assistant_conversations").insert({company_id:companyId,user_id:user.id,title:question.slice(0,120),safe_context:safe||{}}).select("id,company_id,user_id,status").single();
        if(error)throw error;conversation=data;
      }
      const {data:previousMessages,error:historyError}=await admin.from("assistant_messages").select("role,content,created_at").eq("conversation_id",conversation.id).in("role",["user","assistant"]).order("created_at",{ascending:false}).limit(12);
      if(historyError)throw historyError;
      const history=(Array.isArray(previousMessages)?previousMessages:[]).reverse().map(message=>({role:message.role as "user"|"assistant",content:clean(message.content,4000)}));
      const search=new SupabaseDocumentationSearchProvider(userClient),embeddings=new DisabledEmbeddingProvider(),openAIKey=Deno.env.get("OPENAI_API_KEY")||"",model=Deno.env.get("OPENAI_MODEL")||"gpt-5.6-sol";
      const assistant=new ResilientAssistantProvider(openAIKey?new OpenAIResponsesAssistantProvider(openAIKey,model):null);
      let sources=await search.search({question,companyId,safeContext:safe||{},limit:6}),result;
      if(isStockQuestion(question)){
        const stock=sources.find(source=>source.slug==="la-gestion-des-stocks-est-elle-disponible");if(stock)sources=[stock];
        result={answer:"La gestion des stocks fait actuellement partie de la roadmap Piloz et n’est pas encore disponible dans la version actuelle.",answerLevel:"high" as const,provider:"official_roadmap",isRoadmap:true};
      }else result={...(await assistant.answer({question,sources,history,safeContext:safe||{},safetyIdentifier:await privacySafeIdentifier(user.id,companyId)})),isRoadmap:false};
      let unansweredId:string|null=null;if(result.answerLevel==="none"){const {data,error}=await userClient.rpc("record_unanswered_pilo_question",{target_company_id:companyId,question_text:question,safe_context:safe||{}});if(error)throw error;unansweredId=data;}
      const {error:userMessageError}=await admin.from("assistant_messages").insert({conversation_id:conversation.id,role:"user",content:question,safe_context:safe||{}});if(userMessageError)throw userMessageError;
      const {data:assistantMessage,error:assistantMessageError}=await admin.from("assistant_messages").insert({conversation_id:conversation.id,role:"assistant",content:result.answer,answer_level:result.answerLevel,source_article_ids:sources.map(source=>source.id),safe_context:{provider:result.provider,model:result.provider==="openai_responses"?model:null,embedding_provider:embeddings.enabled?"configured":"disabled"}}).select("id").single();if(assistantMessageError)throw assistantMessageError;
      await admin.from("assistant_conversations").update({updated_at:new Date().toISOString(),safe_context:safe||{}}).eq("id",conversation.id);
      return reply(req,{answer:result.answer,answerLevel:result.answerLevel,sources:sources.map(source=>({id:source.id,slug:source.slug,title:source.title,availability:source.availability})),conversationId:conversation.id,messageId:assistantMessage.id,unansweredId,canCreateTicket:result.answerLevel==="none"||result.isRoadmap,isRoadmap:result.isRoadmap,aiEnabled:result.provider==="openai_responses"});
    }
    if(action==="attach-ticket-file"){
      const ticketId=uuid(body.ticketId),fileName=safeName(body.fileName),mimeType=clean(body.mimeType,160).toLowerCase(),size=Number(body.size||0),encoded=String(body.fileBase64||"");
      const extension=fileName.storage.split(".").pop()||"";
      if(!allowedMimes.has(mimeType)||!allowedExtensions[mimeType]?.has(extension))return reply(req,{error:"Format de pièce jointe refusé ou extension incohérente."},400);if(!Number.isInteger(size)||size<1||size>10485760)return reply(req,{error:"La pièce jointe doit faire 10 Mo maximum."},400);if(!encoded)return reply(req,{error:"Le fichier est vide."},400);
      // Refuse oversized base64 payloads before decoding them in memory. A 10 MiB
      // binary file is at most ~13.4 MiB once encoded (plus a small padding margin).
      if(encoded.length>13981020)return reply(req,{error:"La pièce jointe doit faire 10 Mo maximum."},400);
      const {data:allowed,error:accessError}=await userClient.rpc("can_access_support_ticket",{target_ticket_id:ticketId});if(accessError||allowed!==true)return reply(req,{error:"Ticket inaccessible."},403);
      const {data:ticket,error:ticketError}=await admin.from("support_tickets").select("id,company_id").eq("id",ticketId).single();
      if(ticketError||!ticket)return reply(req,{error:"Ticket introuvable."},404);
      if(ticket.company_id!==companyId)return reply(req,{error:"Ticket inaccessible."},403);
      const bytes=bytesFromBase64(encoded);if(bytes.byteLength!==size)return reply(req,{error:"La taille du fichier ne correspond pas à la demande."},400);
      const attachmentId=crypto.randomUUID(),path=`${companyId}/${ticketId}/${attachmentId}/${fileName.storage}`;
      const {error:uploadError}=await admin.storage.from("support-ticket-attachments").upload(path,bytes,{contentType:mimeType,upsert:false});if(uploadError)throw uploadError;
      const {data:attachment,error:insertError}=await admin.from("support_ticket_attachments").insert({id:attachmentId,ticket_id:ticketId,company_id:companyId,uploader_user_id:user.id,storage_path:path,original_name:fileName.original,mime_type:mimeType,size_bytes:size,visibility:"client"}).select("id,original_name,mime_type,size_bytes,created_at").single();if(insertError){await admin.storage.from("support-ticket-attachments").remove([path]);throw insertError;}
      await admin.from("support_ticket_events").insert({ticket_id:ticketId,company_id:companyId,actor_user_id:user.id,event_type:"attachment_added",public_summary:"Pièce jointe ajoutée"});return reply(req,{attachment},201);
    }
    if(action==="download-ticket-file"){
      const attachmentId=uuid(body.attachmentId);
      const {data:attachment,error:attachmentError}=await admin.from("support_ticket_attachments").select("id,ticket_id,company_id,storage_path,original_name,mime_type,size_bytes,visibility").eq("id",attachmentId).single();
      if(attachmentError||!attachment)return reply(req,{error:"Pièce jointe introuvable."},404);
      if(attachment.company_id!==companyId||attachment.visibility!=="client")return reply(req,{error:"Pièce jointe inaccessible."},403);
      const {data:allowed,error:accessError}=await userClient.rpc("can_access_support_ticket",{target_ticket_id:attachment.ticket_id});
      if(accessError||allowed!==true)return reply(req,{error:"Ticket inaccessible."},403);
      const {data:signed,error:signedError}=await admin.storage.from("support-ticket-attachments").createSignedUrl(attachment.storage_path,60,{download:attachment.original_name});
      if(signedError||!signed?.signedUrl)throw signedError||new Error("Lien de téléchargement indisponible.");
      return reply(req,{url:signed.signedUrl,name:attachment.original_name,mimeType:attachment.mime_type,size:attachment.size_bytes,expiresIn:60});
    }
    return reply(req,{error:"Action inconnue."},400);
  }catch(error){console.error("[pilo] request failed",{message:error instanceof Error?error.message:String(error)});return reply(req,{error:error instanceof Error?error.message:"Pilo est temporairement indisponible."},400);}
});
