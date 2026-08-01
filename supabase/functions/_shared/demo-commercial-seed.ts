export const DEMO_COMMERCIAL_SEED_VERSION="2026-08-01-commercial-v1";

type DemoClient={id:string;legal_name?:string|null;first_name?:string|null;last_name?:string|null};
type DemoLine={name:string;description?:string;quantity:number;unit:string;unitPrice:number;unitCost?:number;taxRate?:number};

function isoDate(date:Date){return date.toISOString().slice(0,10);}
function utcDate(year:number,month:number,day:number){return new Date(Date.UTC(year,month,Math.max(1,day),12,0,0));}
function clientName(client:DemoClient){return client.legal_name||`${client.first_name||""} ${client.last_name||""}`.trim();}
function assertResult(error:any,context:string){if(error)throw new Error(`${context}: ${error.code||error.message||"unknown_error"}`);}

async function ensureDocument(admin:any,input:{
 companyId:string;userId:string;clientId:string;seedKey:string;documentType:string;number:string;status:string;
 issueDate:string;dueDate:string;subject:string;lines:DemoLine[];
}){
 const {data:existing,error:lookupError}=await admin.from("documents").select("id,total_incl_tax,status").eq("company_id",input.companyId).contains("metadata",{demo_seed_key:input.seedKey}).limit(1).maybeSingle();
 assertResult(lookupError,`demo_document_lookup_${input.seedKey}`);
 if(existing)return existing;
 const {data:document,error:documentError}=await admin.from("documents").insert({
  company_id:input.companyId,document_type:input.documentType,client_id:input.clientId,status:"draft",
  issue_date:input.issueDate,due_date:input.dueDate,subject:input.subject,currency:"EUR",language:"fr",
  payment_terms:"30 jours",payment_method:"Virement bancaire",created_by:input.userId,
  metadata:{demo:true,demo_seed_key:input.seedKey,demo_seed_version:DEMO_COMMERCIAL_SEED_VERSION}
 }).select("id,total_incl_tax,status").single();
 assertResult(documentError,`demo_document_insert_${input.seedKey}`);
 const {error:linesError}=await admin.from("document_lines").insert(input.lines.map((line,index)=>({
  company_id:input.companyId,document_id:document.id,position:index+1,line_type:"free_item",name:line.name,
  description:line.description||null,quantity:line.quantity,unit:line.unit,unit_cost_snapshot:line.unitCost||0,
  unit_price:line.unitPrice,discount_rate:0,tax_rate:line.taxRate??20,created_by:input.userId
 })));
 assertResult(linesError,`demo_document_lines_${input.seedKey}`);
 const validatedAt=new Date(`${input.issueDate}T12:00:00.000Z`).toISOString();
 const {data:finalDocument,error:finalError}=await admin.from("documents").update({number:input.number,status:input.status,validated_at:validatedAt}).eq("id",document.id).select("id,total_incl_tax,status").single();
 assertResult(finalError,`demo_document_finalize_${input.seedKey}`);
 return finalDocument;
}

async function ensurePayment(admin:any,input:{companyId:string;userId:string;documentId:string;amount:number;paidAt:string;reference:string}){
 const {data:existing,error:lookupError}=await admin.from("payments").select("id").eq("company_id",input.companyId).eq("reference",input.reference).limit(1).maybeSingle();
 assertResult(lookupError,`demo_payment_lookup_${input.reference}`);
 if(existing)return existing;
 const {data:payment,error}=await admin.from("payments").insert({
  company_id:input.companyId,document_id:input.documentId,amount:input.amount,currency:"EUR",paid_at:input.paidAt,
  payment_method:"Virement bancaire",reference:input.reference,status:"confirmed",created_by:input.userId
 }).select("id").single();
 assertResult(error,`demo_payment_insert_${input.reference}`);
 return payment;
}

export async function seedDemoCommercialData(admin:any,companyId:string,userId:string){
 const now=new Date(),year=now.getUTCFullYear(),month=now.getUTCMonth(),today=Math.max(1,now.getUTCDate());
 const currentIssue=isoDate(utcDate(year,month,Math.min(today,10)));
 const currentDue=isoDate(utcDate(year,month+1,Math.min(today,10)));
 const previousIssue=isoDate(utcDate(year,month-1,10));
 const previousDue=isoDate(utcDate(year,month-1,25));
 const paymentAt=utcDate(year,month,Math.min(today,10)).toISOString();
 const {data:clients,error:clientsError}=await admin.from("clients").select("id,legal_name,first_name,last_name").eq("company_id",companyId);
 assertResult(clientsError,"demo_clients_lookup");
 const byName=new Map((clients||[]).map((client:DemoClient)=>[clientName(client),client]));
 const nova=byName.get("Nova Bâtiment"),atelier=byName.get("Atelier Horizon"),camille=byName.get("Camille Martin");
 if(!nova||!atelier||!camille)throw new Error("demo_commercial_clients_missing");

 const quoteWebsite=await ensureDocument(admin,{companyId,userId,clientId:atelier.id,seedKey:"quote-website",documentType:"quote",number:"DEV-DEMO-1001",status:"sent",issueDate:currentIssue,dueDate:currentDue,subject:"Refonte du site vitrine",lines:[
  {name:"Audit et cadrage",description:"Ateliers de cadrage et recommandations",quantity:20,unit:"heure",unitPrice:95,unitCost:45},
  {name:"Conception du site vitrine",description:"Création et mise en ligne",quantity:1,unit:"forfait",unitPrice:3520,unitCost:1400}
 ]});
 const quoteMaintenance=await ensureDocument(admin,{companyId,userId,clientId:nova.id,seedKey:"quote-maintenance",documentType:"quote",number:"DEV-DEMO-1002",status:"accepted",issueDate:currentIssue,dueDate:currentDue,subject:"Maintenance annuelle",lines:[
  {name:"Maintenance et assistance",description:"Forfait annuel",quantity:12,unit:"mois",unitPrice:290,unitCost:120}
 ]});
 const invoiceInstallation=await ensureDocument(admin,{companyId,userId,clientId:nova.id,seedKey:"invoice-installation",documentType:"invoice",number:"FAC-DEMO-2001",status:"partially_paid",issueDate:currentIssue,dueDate:currentDue,subject:"Installation et mise en service",lines:[
  {name:"Installation et mise en service",quantity:18,unit:"heure",unitPrice:450,unitCost:180}
 ]});
 const invoiceSubscription=await ensureDocument(admin,{companyId,userId,clientId:atelier.id,seedKey:"invoice-subscription",documentType:"invoice",number:"FAC-DEMO-2002",status:"paid",issueDate:currentIssue,dueDate:currentDue,subject:"Accompagnement mensuel",lines:[
  {name:"Accompagnement mensuel",quantity:12,unit:"mois",unitPrice:145,unitCost:65}
 ]});
 const invoiceOverdue=await ensureDocument(admin,{companyId,userId,clientId:camille.id,seedKey:"invoice-overdue",documentType:"invoice",number:"FAC-DEMO-2003",status:"overdue",issueDate:previousIssue,dueDate:previousDue,subject:"Conseil opérationnel",lines:[
  {name:"Conseil opérationnel",quantity:6,unit:"heure",unitPrice:300,unitCost:110}
 ]});
 await ensurePayment(admin,{companyId,userId,documentId:invoiceInstallation.id,amount:2500,paidAt:paymentAt,reference:"DEMO-REG-2001"});
 await ensurePayment(admin,{companyId,userId,documentId:invoiceSubscription.id,amount:Number(invoiceSubscription.total_incl_tax)||2088,paidAt:paymentAt,reference:"DEMO-REG-2002"});

 const opportunityMarker=`[${DEMO_COMMERCIAL_SEED_VERSION}:opportunity-transformation]`;
 const {data:opportunities,error:opportunitiesError}=await admin.from("opportunities").select("id").eq("company_id",companyId).ilike("notes",`%${opportunityMarker}%`).limit(1);
 assertResult(opportunitiesError,"demo_opportunity_lookup");
 if(!(opportunities||[]).length){
  const {error}=await admin.from("opportunities").insert({company_id:companyId,client_id:nova.id,name:"Transformation des outils de gestion",stage:"proposal",amount:12500,probability:45,owner_user_id:userId,next_action_at:utcDate(year,month,Math.min(today+5,28)).toISOString(),notes:`Opportunité fictive de démonstration ${opportunityMarker}`,created_by:userId});
  assertResult(error,"demo_opportunity_insert");
 }
 return{version:DEMO_COMMERCIAL_SEED_VERSION,documentIds:[quoteWebsite.id,quoteMaintenance.id,invoiceInstallation.id,invoiceSubscription.id,invoiceOverdue.id]};
}
