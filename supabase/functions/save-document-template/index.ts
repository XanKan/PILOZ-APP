import { createClient } from "npm:@supabase/supabase-js@2";
import sanitizeHtml from "npm:sanitize-html@2.17.0";
import { corsHeaders, json } from "../_shared/http.ts";

function cleanHtml(input:string){
 return sanitizeHtml(String(input||''),{
  allowedTags:['header','footer','main','section','article','aside','div','span','p','br','hr','h1','h2','h3','h4','h5','h6','strong','b','em','i','u','small','ol','ul','li','table','thead','tbody','tfoot','tr','th','td','img','a','address','blockquote'],
  allowedAttributes:{'*':['class','title','data-block'],img:['src','alt','width','height'],a:['href','title'],td:['colspan','rowspan'],th:['colspan','rowspan']},
  allowedSchemes:[],allowProtocolRelative:false,disallowedTagsMode:'discard',enforceHtmlBoundary:true
 });
}
function sanitizeCss(input:string){return String(input||'').replace(/@import[^;]+;?/gi,'').replace(/url\s*\([^)]*\)/gi,'').replace(/expression\s*\([^)]*\)/gi,'').replace(/<\/?style\b[^>]*>/gi,'').replace(/[<>]/g,'');}
Deno.serve(async(req)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:corsHeaders});if(req.method!=='POST')return json({error:'Méthode non autorisée'},405);
 const auth=req.headers.get('authorization');if(!auth)return json({error:'Authentification requise'},401);
 const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
 const userClient=createClient(url,anon,{global:{headers:{Authorization:auth}}}),{data:{user}}=await userClient.auth.getUser();if(!user)return json({error:'Session invalide'},401);
 const body=await req.json(),admin=createClient(url,secret),{data:member}=await admin.from('company_members').select('role').eq('company_id',body.companyId).eq('user_id',user.id).maybeSingle();if(!member||!['owner','admin'].includes(member.role))return json({error:'Accès refusé'},403);
 const {data,error}=await admin.rpc('save_document_template_version',{target_company_id:body.companyId,target_user_id:user.id,target_template_id:body.templateId||null,target_name:String(body.name||'').trim(),target_document_type:body.documentType,target_language:body.language||'fr',target_status:body.status||'active',target_is_default:!!body.isDefault,target_visual_schema:body.visualSchema||{},target_html:cleanHtml(body.html),target_css:sanitizeCss(body.css),target_comment:body.comment||'Nouvelle version',target_layout_key:body.layoutKey||'classic',target_color_settings:body.colorSettings||{},target_logo_settings:body.logoSettings||{},target_visible_columns:body.visibleColumns||[],target_header_fields:body.headerFields||[],target_footer_id:body.footerId||null,target_bank_details_visibility:body.bankDetailsVisibility||'footer',target_document_title:body.documentTitle||null,target_free_field:body.freeField||null,target_client_profile:body.clientProfile||{show_email:true,show_phone:true},target_issuer_profile:body.issuerProfile||{},target_payment_methods:body.paymentMethods||['bank_transfer']});
 if(error)return json({error:error.code==='42501'?'Accès refusé':'Impossible d’enregistrer cette version.'},error.code==='42501'?403:400);
 return json(data);
});
