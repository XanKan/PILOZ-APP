export type DocumentationSource={id:string;slug:string;title:string;summary:string;excerpt:string;categoryName:string;availability:string;publishedAt:string|null};
export type DocumentationSearchInput={question:string;companyId:string;safeContext:Record<string,unknown>;limit?:number};
export interface DocumentationSearchProvider{search(input:DocumentationSearchInput):Promise<DocumentationSource[]>;}
export interface AssistantProvider{answer(input:{question:string;sources:DocumentationSource[]}):Promise<{answer:string;answerLevel:"high"|"medium"|"low"|"none"}>;}
export interface EmbeddingProvider{enabled:boolean;embed(text:string):Promise<number[]>;}

export class SupabaseDocumentationSearchProvider implements DocumentationSearchProvider{
  constructor(private client:any){}
  async search(input:DocumentationSearchInput){
    const {data,error}=await this.client.rpc("search_piloz_documentation",{search_query:input.question,target_company_id:input.companyId,safe_context:input.safeContext,result_limit:input.limit||6});
    if(error)throw error;
    return (Array.isArray(data)?data:[]).map((row:any)=>({id:row.article_id,slug:row.slug,title:row.title,summary:row.summary||"",excerpt:row.excerpt||"",categoryName:row.category_name||"Documentation",availability:row.availability||"available",publishedAt:row.published_at||null}));
  }
}

export class OfficialExtractiveAssistantProvider implements AssistantProvider{
  async answer(input:{question:string;sources:DocumentationSource[]}){
    if(!input.sources.length)return{answer:"Je n’ai pas trouvé de réponse suffisamment précise dans la documentation Piloz.",answerLevel:"none" as const};
    const primary=input.sources[0],text=String(primary.excerpt||primary.summary||"").replace(/\s+/g," ").trim();
    return{answer:text||`La documentation officielle contient un article intitulé « ${primary.title} ». Consultez la source ci-dessous pour le détail.`,answerLevel:input.sources.length>1?"high" as const:"medium" as const};
  }
}

export class DisabledEmbeddingProvider implements EmbeddingProvider{
  enabled=false;
  async embed(_text:string){return[];}
}
