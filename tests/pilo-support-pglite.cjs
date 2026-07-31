const {loadPGlite,bootstrap,setIdentity}=require('./helpers/pglite-bootstrap.cjs');

const owner='11111111-1111-4111-8111-111111111111';
const other='22222222-2222-4222-8222-222222222222';
const companyA='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const companyB='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
function assert(value,message){if(!value)throw new Error(message);}

(async()=>{
 const {PGlite,pgcrypto}=loadPGlite(),db=new PGlite({extensions:{pgcrypto}});
 try{
  await bootstrap(db);
  await db.exec(`
   insert into auth.users(id,email) values ('${owner}','owner@piloz-a.test'),('${other}','owner@piloz-b.test');
   insert into public.companies(id,owner_user_id,name) values ('${companyA}','${owner}','Piloz A'),('${companyB}','${other}','Piloz B');
   insert into public.company_members(company_id,user_id,role) values ('${companyA}','${owner}','owner'),('${companyB}','${other}','owner');
  `);
  await setIdentity(db,owner);
  const conversation=(await db.query(`insert into public.assistant_conversations(company_id,user_id,title,safe_context) values($1,$2,'Test Pilo','{"route":"sales/invoices","token":"secret"}') returning id`,[companyA,owner])).rows[0];
  const created=(await db.query(`select to_jsonb(public.create_support_ticket(
   target_company_id=>$1,target_subject=>'Finalisation impossible',target_description=>'La finalisation de la facture reste bloquée après validation.',target_category=>'invoices',target_module=>'Factures',target_type=>'incident',target_priority=>'high',
   target_context=>'${JSON.stringify({route:'sales/invoices',module:'sales',token:'must-not-survive'})}'::jsonb,target_source=>'pilo',
   target_details=>'${JSON.stringify({impact:'Facturation bloquée',frequency:'always',blocking:'total',unexpected_secret:'remove-me'})}'::jsonb,target_assistant_conversation_id=>$2
  )) ticket`,[companyA,conversation.id])).rows[0].ticket;
  assert(/^SUP-\d{4}-\d{6}$/.test(created.ticket_number),'numéro de ticket non atomique');
  assert(created.request_details.impact==='Facturation bloquée'&&!('unexpected_secret' in created.request_details),'détails de demande non nettoyés');
  assert(created.safe_context.route==='sales/invoices'&&!('token' in created.safe_context),'contexte assistant non nettoyé');
  assert(created.assistant_conversation_id===conversation.id,'conversation Pilo non liée');
  const shortTicket=(await db.query(`select to_jsonb(public.create_support_ticket(
   target_company_id=>$1,target_subject=>'TEST',target_description=>'TEST',target_category=>'usage',target_module=>'help',target_type=>'support',target_priority=>'normal'
  )) ticket`,[companyA])).rows[0].ticket;
  assert(shortTicket.subject==='TEST'&&shortTicket.description==='TEST','un ticket visiblement complété avec quatre caractères doit être accepté');
  const visibleMessages=(await db.query('select author_kind,visibility from public.support_ticket_messages where ticket_id=$1',[created.id])).rows;
  assert(visibleMessages.length===1&&visibleMessages[0].visibility==='client','message client initial absent');
  await db.exec('reset role');
  const platformNotices=(await db.query("select event_type,company_id,title from public.platform_notifications where company_id=$1",[companyA])).rows;
  const supportTriggers=(await db.query("select tgname,tgenabled from pg_trigger where tgrelid in('public.support_tickets'::regclass,'public.support_ticket_messages'::regclass) and not tgisinternal")).rows;
  assert(platformNotices.some(item=>item.event_type==='support_ticket_created'),'notification de file support absente: '+JSON.stringify({platformNotices,supportTriggers}));
  await db.query("insert into public.support_ticket_messages(ticket_id,author_kind,visibility,body,sent_at) values($1,'support','client','Nous analysons votre demande.',now())",[created.id]);
  const clientNotice=(await db.query("select count(*)::int count from public.notifications where notification_type='support_reply' and company_id=$1 and user_id=$2",[companyA,owner])).rows[0].count;
  assert(clientNotice===1,'notification client de réponse support absente');

  await setIdentity(db,other);
  const foreign=(await db.query('select count(*)::int count from public.support_ticket_client_view where id=$1',[created.id])).rows[0].count;
  assert(foreign===0,'fuite interentreprises sur les tickets');
  const foreignAccess=(await db.query('select public.can_access_support_ticket($1) allowed',[created.id])).rows[0].allowed;
  assert(foreignAccess===false,'RPC d’accès interentreprises trop permissive');

  const docs=(await db.query("select count(*)::int count from public.knowledge_categories where active")).rows[0].count;
  assert(docs===35,'catalogue documentaire incomplet');
  const electronicDocs=(await db.query("select count(*)::int count from public.knowledge_articles article join public.knowledge_categories category on category.id=article.category_id where category.slug='facturation-electronique' and article.status='published'")).rows[0].count;
  assert(electronicDocs>=27,'corpus facturation électronique incomplet');
  const falseClaims=(await db.query("select count(*)::int count from public.knowledge_articles where lower(content) like '%piloz est certifié nf525%' or lower(content) like '%piloz est certifié nf203%' or lower(content) like '%piloz est une plateforme agréée.%' or lower(content) like '%piloz garantit la conformité légale complète%'")).rows[0].count;
  assert(falseClaims===0,'revendication réglementaire non prouvée');
  const stock=(await db.query("select title,content,availability from public.knowledge_articles where slug='la-gestion-des-stocks-est-elle-disponible'")).rows[0];
  assert(stock.availability==='roadmap','stock non classé roadmap');
  assert(stock.content==='La gestion des stocks fait partie de la roadmap Piloz et n’est pas encore disponible dans la version actuelle. Sa disponibilité sera annoncée officiellement lors de sa mise en production.','formulation officielle stock altérée');
  const operationalStock=(await db.query("select count(*)::int count from public.knowledge_articles where slug<>'la-gestion-des-stocks-est-elle-disponible' and availability<>'roadmap' and (lower(title) ~ '(stock|inventaire|entrepôt)' or lower(content) ~ '(gérer le stock|mouvement de stock|inventaire de stock)')")).rows[0].count;
  assert(operationalStock===0,'documentation opérationnelle stock interdite');
  await db.exec('reset role');
  const stockId=(await db.query("select id from public.knowledge_articles where slug='la-gestion-des-stocks-est-elle-disponible'")).rows[0].id;
  await db.query("insert into public.knowledge_article_modules(article_id,module_key) values($1,'settings')",[stockId]);
  await db.query("insert into public.knowledge_article_roles(article_id,role_key) values($1,'administrator')",[stockId]);
  await setIdentity(db,owner);
  const wrongModule=(await db.query("select count(*)::int count from public.search_piloz_documentation('gestion des stocks',$1,'{\"module\":\"sales\",\"app_version\":\"1.0.0\"}'::jsonb,8) where slug='la-gestion-des-stocks-est-elle-disponible'",[companyA])).rows[0].count;
  const allowedModule=(await db.query("select count(*)::int count from public.search_piloz_documentation('gestion des stocks',$1,'{\"module\":\"settings\",\"role\":\"owner\",\"app_version\":\"1.0.0\"}'::jsonb,8) where slug='la-gestion-des-stocks-est-elle-disponible'",[companyA])).rows[0].count;
  assert(wrongModule===1&&allowedModule===1,'la documentation doit rester trouvable hors de son module de prédilection');
  await db.exec('reset role');
  await db.query("update public.knowledge_articles set app_version_min='9.0.0' where id=$1",[stockId]);
  await setIdentity(db,owner);
  const incompatibleVersion=(await db.query("select count(*)::int count from public.search_piloz_documentation('gestion des stocks',$1,'{\"module\":\"settings\",\"app_version\":\"1.0.0\"}'::jsonb,8) where slug='la-gestion-des-stocks-est-elle-disponible'",[companyA])).rows[0].count;
  const compatibleVersion=(await db.query("select count(*)::int count from public.search_piloz_documentation('gestion des stocks',$1,'{\"module\":\"settings\",\"app_version\":\"9.0.0\"}'::jsonb,8) where slug='la-gestion-des-stocks-est-elle-disponible'",[companyA])).rows[0].count;
  assert(incompatibleVersion===0&&compatibleVersion===1,'filtrage documentaire par version incorrect');
  console.log(JSON.stringify({ok:true,ticket:created.ticket_number,categories:docs,electronicDocs,stock:stock.availability,notifications:clientNotice,moduleRoleVersion:true}));
 }finally{await db.close();}
})().catch(error=>{console.error(error);process.exit(1);});
