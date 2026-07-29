begin;

-- Replace the short generic invoice entry with an operational guide that can
-- answer a user directly without exposing the internal documentation template.
update public.knowledge_articles
set summary='Créer une facture, l’enregistrer en brouillon puis la finaliser sans perdre les informations saisies.',
    content=$article$
## Créer une facture

1. Ouvrez **Ventes > Factures**.
2. Cliquez sur **Créer une facture**.
3. Sélectionnez le client. S’il n’existe pas encore, utilisez **Créer un nouveau client** depuis le sélecteur.
4. Vérifiez la date d’émission et la date d’échéance.
5. Ajoutez chaque article ou service. Contrôlez la quantité, l’unité, le prix hors taxes et le taux de TVA.
6. Complétez si nécessaire les conditions de paiement, la remise globale, l’acompte et les notes internes.

## Enregistrer un brouillon

Cliquez sur **Enregistrer comme brouillon** pour reprendre la facture plus tard. Le brouillon reste modifiable et utilise un numéro provisoire. Il ne constitue pas une facture définitive.

## Finaliser la facture

Cliquez sur **Finaliser la facture**, contrôlez les dates dans la fenêtre de confirmation puis validez. Le client et au moins une ligne cohérente sont obligatoires. Piloz attribue alors le numéro définitif, génère le document final et ouvre automatiquement la consultation.

## Après la finalisation

Une facture finalisée ne se modifie et ne se supprime plus directement. Pour corriger un montant ou une ligne, ouvrez la facture puis créez un avoir. Pour enregistrer un encaissement, utilisez les actions de paiement dans le panneau de droite.

## Si la finalisation est bloquée

Vérifiez le client, les dates, la chronologie, les lignes, les totaux, la TVA et le régime fiscal de l’entreprise. Le brouillon et toutes les informations saisies restent conservés après un échec.
$article$,
    current_version=current_version+1,
    last_reviewed_at=now(),
    updated_at=now()
where slug='creer-finaliser-facture';

insert into public.knowledge_article_versions(article_id,version_number,title,summary,content,availability,visibility,change_summary)
select id,current_version,title,summary,content,availability,visibility,'Guide de création et finalisation détaillé pour Pilo'
from public.knowledge_articles article
where slug='creer-finaliser-facture'
  and not exists(select 1 from public.knowledge_article_versions version where version.article_id=article.id and version.version_number=article.current_version);

insert into public.knowledge_article_chunks(article_id,article_version,chunk_index,heading,content)
select id,current_version,0,title,content
from public.knowledge_articles
where slug='creer-finaliser-facture'
on conflict(article_id,article_version,chunk_index) do update set heading=excluded.heading,content=excluded.content;

-- Keep broad natural-language matching but provide enough of the article for
-- actionable answers and strongly prefer the operational invoice guide over
-- CII/UBL/Factur-X definitions for a simple "comment faire une facture" query.
create or replace function public.search_piloz_documentation(
 search_query text,
 target_company_id uuid default null,
 safe_context jsonb default '{}'::jsonb,
 result_limit integer default 8
) returns table(
 article_id uuid,slug text,title text,summary text,excerpt text,category_name text,
 availability text,published_at timestamptz,rank real
) language plpgsql security definer set search_path=public,pg_temp as $$
declare
 normalized_query text:=left(trim(coalesce(search_query,'')),500);
 safe jsonb:=public.sanitize_assistant_context(coalesce(safe_context,'{}'::jsonb));
 allowed_company uuid;
 trusted_role text;
 requested_module text:=nullif(left(coalesce(safe->>'module',''),80),'');
 requested_version bigint:=public.piloz_version_number(safe->>'app_version');
 query_terms text[];
 found_count integer:=0;
 operational_invoice_query boolean:=false;
 technical_invoice_query boolean:=false;
begin
 if auth.uid() is null then raise exception 'Authentification requise' using errcode='42501'; end if;
 if length(normalized_query)<2 then return; end if;

 operational_invoice_query:=lower(normalized_query) like '%factur%' and lower(normalized_query) ~ '(comment|créer|creer|faire|finaliser|valider|enregistrer|nouvelle|nouveau|ouvrir)';
 technical_invoice_query:=lower(normalized_query) ~ '(cii|ubl|xml|factur-x|factur x|pdp|plateforme agréée|plateforme agreee|facturation électronique|facturation electronique)';

 select coalesce(array_agg(term),array[]::text[]) into query_terms
 from (
  select distinct token as term
  from regexp_split_to_table(lower(normalized_query),'[^[:alnum:]]+') token
  where length(token)>=2
 ) terms;

 if target_company_id is not null and public.is_company_member(target_company_id) then
  allowed_company:=target_company_id;
  select coalesce(role.system_key,role.role_key,member.role) into trusted_role
  from public.company_members member
  left join public.company_roles role on role.id=member.role_id and role.company_id=member.company_id and role.active
  where member.company_id=allowed_company and member.user_id=auth.uid()
   and coalesce(member.platform_status,'active')='active'
  limit 1;
 end if;

 return query
 with candidates as (
  select article.id,article.slug,article.title,article.summary,
   left(article.content,2400) as excerpt,
   category.name as category_name,article.availability,article.published_at,
   ts_rank(article.search_vector,websearch_to_tsquery('french',normalized_query)) as full_text_rank,
   coalesce((
    select count(*)::integer from unnest(query_terms) term
    where lower(concat_ws(' ',article.title,article.summary,article.content)) like '%'||term||'%'
   ),0) as token_hits,
   exists(select 1 from public.knowledge_article_modules module where module.article_id=article.id and module.module_key=requested_module) as module_match
  from public.knowledge_articles article
  join public.knowledge_categories category on category.id=article.category_id and category.active
  where article.status='published' and article.language='fr'
   and article.visibility in('public','authenticated','company')
   and (article.visibility<>'company' or article.company_id=allowed_company)
   and (not exists(select 1 from public.knowledge_article_roles restriction where restriction.article_id=article.id)
    or (trusted_role is not null and exists(select 1 from public.knowledge_article_roles restriction where restriction.article_id=article.id and restriction.role_key=trusted_role)))
   and (article.app_version_min is null or requested_version is null or public.piloz_version_number(article.app_version_min)<=requested_version)
   and (article.app_version_max is null or requested_version is null or public.piloz_version_number(article.app_version_max)>=requested_version)
 ), ranked as (
  select candidate.*,
   (greatest(candidate.full_text_rank,
      case when candidate.title ilike '%'||normalized_query||'%' then 0.8 else 0 end,
      case when candidate.summary ilike '%'||normalized_query||'%' then 0.55 else 0 end)
    +least(candidate.token_hits,6)*0.08
    +case when candidate.module_match then 0.12 else 0 end
    +case when operational_invoice_query and not technical_invoice_query and candidate.slug='creer-finaliser-facture' then 3.0 else 0 end
    -case when operational_invoice_query and not technical_invoice_query and candidate.slug in('comprendre-cii','comprendre-ubl','comprendre-factur-x','difference-pdf-facture-electronique') then 0.8 else 0 end)::real as relevance
  from candidates candidate
  where candidate.full_text_rank>0
   or candidate.title ilike '%'||normalized_query||'%'
   or candidate.summary ilike '%'||normalized_query||'%'
   or candidate.token_hits>0
 )
 select ranked.id,ranked.slug,ranked.title,ranked.summary,ranked.excerpt,ranked.category_name,
  ranked.availability,ranked.published_at,ranked.relevance
 from ranked
 order by ranked.relevance desc,ranked.published_at desc nulls last
 limit greatest(1,least(coalesce(result_limit,8),20));

 get diagnostics found_count=row_count;
 insert into public.knowledge_search_events(company_id,user_id,query,safe_context,result_count)
 values(allowed_company,auth.uid(),normalized_query,safe,found_count);
end;
$$;

grant execute on function public.search_piloz_documentation(text,uuid,jsonb,integer) to authenticated;

commit;
