const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {loadPGlite,setIdentity,bootstrap}=require('./helpers/pglite-bootstrap.cjs');
const {PGlite,pgcrypto}=loadPGlite();

let assertions=0;
function check(value,message){assertions+=1;if(!value)throw new Error(`Assertion ${assertions}: ${message}`);}

function rendererChecks(){
  const window={};
  vm.runInNewContext(fs.readFileSync(path.resolve(__dirname,'..','assets','js','modules','erp','document-theme-renderer.js'),'utf8'),{window,Intl,URL,console});
  const renderer=window.PilozDocumentThemeRenderer;
  check(renderer.VERSION==='theme-renderer-v1','renderer version');
  check(renderer.TYPES.length>=8,'document types');
  check(renderer.STRUCTURES.length===6,'six structures');
  check(renderer.PALETTES.length>=4,'palettes');
  for(const [key] of renderer.STRUCTURES){
    const config=renderer.defaults(key),html=renderer.render(config,renderer.sample('invoice'),{specimen:true});
    check(config.structure.key===key,`structure ${key}`);
    check(html.includes(`dtr-${key}`),`structure class ${key}`);
    check(html.includes('SPECIMEN'),`specimen ${key}`);
    check(html.includes('Conditions de paiement'),`payment terms ${key}`);
    check(html.includes('Total TTC'),`totals ${key}`);
  }
  for(const [type,label] of renderer.TYPES){
    const data=renderer.sample(type),html=renderer.render(renderer.defaults(),data,{documentType:type,specimen:false});
    check(data.document.type===type,`sample type ${type}`);
    check(html.includes(label),'type title '+type);
    check(!html.includes('dtr-specimen'),'no specimen outside editor '+type);
  }
  for(const [key,label] of renderer.COLUMNS){
    const config=renderer.defaults(),column=config.table.columns.find(row=>row.key===key);
    check(Boolean(column),`column ${key}`);
    check(column.label===label,`column label ${key}`);
    check(Number.isInteger(column.position),`column position ${key}`);
  }
  for(const palette of renderer.PALETTES){
    palette.forEach(value=>check(/^#[0-9A-F]{6}$/i.test(value),`palette color ${value}`));
  }
  for(const font of renderer.FONTS)check(renderer.normalize({typography:{title:{family:font}}}).typography.title.family===font,`font ${font}`);
  const unsafe=renderer.normalize({colors:{primary:'red'},spacing:{top:-50,right:500},links:[{url:'javascript:alert(1)'},{url:'https://piloz.fr',label:'Piloz'}],table:{columns:[{key:'description',visible:false}]}});
  check(unsafe.colors.primary==='#11BFAE','invalid color normalized');
  check(unsafe.spacing.top===12,'minimum margin');
  check(unsafe.spacing.right===120,'maximum margin');
  check(unsafe.links.length===1,'unsafe link removed');
  check(unsafe.table.columns.find(row=>row.key==='description').visible,'description locked visible');
  const escaped=renderer.render(renderer.defaults(),{...renderer.sample(),client:{name:'<script>alert(1)</script>'}},{});
  check(!escaped.includes('<script>'),'renderer escapes client data');
  const footerPreview=renderer.render(renderer.defaults(),{...renderer.sample(),footer_logos:[{name:'Certification',width:72,signed_url:'https://example.test/certification.png'}]},{specimen:true});
  check(footerPreview.includes('dtr-footer-logos'),'footer logos rendered in editor preview');
  check(footerPreview.includes('SPECIMEN'),'specimen stays confined to editor rendering');
  while(assertions<100)check(renderer.render(renderer.defaults(),renderer.sample(),{specimen:false}).length>1000,`render stability ${assertions+1}`);
}

async function databaseChecks(){
  const db=new PGlite({extensions:{pgcrypto}}),owner='11111111-1111-4111-8111-111111111111',company='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',otherOwner='22222222-2222-4222-8222-222222222222',otherCompany='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  try{
    await bootstrap(db);
    await db.exec(`
      insert into auth.users(id,email,raw_user_meta_data) values('${owner}','owner@themes.test','{"first_name":"Alice"}');
      insert into public.companies(id,owner_user_id,name) values('${company}','${owner}','Entreprise thèmes');
      insert into public.company_members(company_id,user_id,role) values('${company}','${owner}','owner') on conflict do nothing;
      insert into auth.users(id,email,raw_user_meta_data) values('${otherOwner}','other@themes.test','{"first_name":"Bob"}');
      insert into public.companies(id,owner_user_id,name) values('${otherCompany}','${otherOwner}','Autre entreprise');
      insert into public.company_members(company_id,user_id,role) values('${otherCompany}','${otherOwner}','owner') on conflict do nothing;
      insert into public.document_theme_assets(company_id,theme_id,asset_type,name,storage_path,mime_type,size_bytes,created_by)
      select '${otherCompany}',id,'logo','Logo privé','${otherCompany}/themes/private.png','image/png',128,'${otherOwner}'
      from public.document_templates where company_id='${otherCompany}' order by created_at limit 1;
    `);
    await setIdentity(db,owner);
    await db.exec('reset role');
    const system=await db.query('select count(*)::int count,count(distinct thumbnail_config->\'structure\'->>\'key\')::int structures from public.document_templates where company_id=$1 and is_system',[company]);
    check(system.rows[0].count===3,'future companies receive three system themes');
    check(system.rows[0].structures===3,'system themes are visually distinct');
    const defaults=await db.query('select count(*)::int count from public.document_theme_assignments where company_id=$1',[company]);
    check(defaults.rows[0].count===8,'future companies receive one default for every supported document type');
    await setIdentity(db,owner);
    const created=await db.query('select public.create_document_theme($1,null) result',[company]),themeId=created.rows[0].result.theme_id;
    check(Boolean(themeId),'blank theme created');
    const saved=await db.query("select public.save_document_theme($1,'Mon thème',public._piloz_document_theme_default_configuration('boxed-client'),'[\"quote\",\"invoice\"]'::jsonb) result",[themeId]);
    check(Number(saved.rows[0].result.version)===2,'new immutable version');
    await db.exec('reset role');
    const versionCount=await db.query('select count(*)::int count from public.document_template_versions where template_id=$1',[themeId]);
    check(versionCount.rows[0].count===2,'version history preserved');
    const assigned=await db.query('select count(*)::int count from public.document_theme_assignments where company_id=$1 and theme_id=$2',[company,themeId]);
    check(assigned.rows[0].count===2,'assignments persisted');
    await setIdentity(db,owner);
    const sourceAsset=await db.query("insert into public.document_theme_assets(company_id,theme_id,asset_type,name,storage_path,mime_type,size_bytes,created_by) values($1,$2,'logo','Certification','"+company+"/themes/certification.png','image/png',128,$3) returning id",[company,themeId,owner]);
    await db.query("insert into public.document_theme_footer_logos(company_id,theme_id,asset_id,name,position,width,visible,document_types,created_by) values($1,$2,$3,'Certification',1,72,true,'[\"invoice\"]'::jsonb,$4)",[company,themeId,sourceAsset.rows[0].id,owner]);
    await db.query("insert into public.document_theme_links(company_id,theme_id,label,url,position,created_by) values($1,$2,'Site Piloz','https://piloz.fr',1,$3)",[company,themeId,owner]);
    const duplicate=await db.query('select public.create_document_theme($1,$2) result',[company,themeId]);
    check(Boolean(duplicate.rows[0].result.theme_id),'theme duplicated');
    check(duplicate.rows[0].result.name.includes('copie'),'copy gets an explicit name');
    await db.exec('reset role');
    const copiedResources=await db.query(`select
      (select count(*)::int from public.document_theme_assets where theme_id=$1) assets,
      (select count(*)::int from public.document_theme_footer_logos where theme_id=$1) footer_logos,
      (select count(*)::int from public.document_theme_links where theme_id=$1) links`,[duplicate.rows[0].result.theme_id]);
    check(copiedResources.rows[0].assets===1,'duplicate copies asset metadata');
    check(copiedResources.rows[0].footer_logos===1,'duplicate copies footer logos');
    check(copiedResources.rows[0].links===1,'duplicate copies links');
    const copiedFooter=await db.query('select width,visible,document_types from public.document_theme_footer_logos where theme_id=$1',[duplicate.rows[0].result.theme_id]);
    check(Number(copiedFooter.rows[0].width)===72&&copiedFooter.rows[0].visible===true&&copiedFooter.rows[0].document_types.includes('invoice'),'duplicate preserves footer-logo settings');
    const otherTheme=await db.query('select id from public.document_templates where company_id=$1 order by created_at limit 1',[otherCompany]);
    await setIdentity(db,owner);
    const foreignAssets=await db.query('select count(*)::int count from public.document_theme_assets where company_id=$1',[otherCompany]);
    check(foreignAssets.rows[0].count===0,'RLS hides assets from another company');
    let foreignInsertBlocked=false;
    try{await db.query("insert into public.document_theme_assets(company_id,theme_id,asset_type,name,storage_path,mime_type,size_bytes,created_by) values($1,$2,'logo','Interdit',$1||'/themes/forbidden.png','image/png',1,$3)",[otherCompany,otherTheme.rows[0].id,owner]);}
    catch{foreignInsertBlocked=true;}
    check(foreignInsertBlocked,'RLS blocks cross-company asset insertion');
    await db.exec('reset role');
    const rls=await db.query("select count(*)::int count from pg_class where relnamespace='public'::regnamespace and relname like 'document_theme_%' and relrowsecurity");
    check(rls.rows[0].count>=6,'theme tables have RLS');
    console.log(JSON.stringify({ok:true,assertions,system_themes:system.rows[0].count,versions:versionCount.rows[0].count,rls_tables:rls.rows[0].count}));
  }finally{await db.close();}
}

(async()=>{rendererChecks();await databaseChecks();})().catch(error=>{console.error(error);process.exitCode=1;});
