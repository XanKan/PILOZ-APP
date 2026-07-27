const fs=require('fs');
const path=require('path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const catalog=read('assets/js/modules/erp/erp-catalog-v2.js');
const editor=read('assets/js/modules/erp/erp-document-editor-v2.js');
const accounting=read('assets/js/modules/erp/erp-accounting-extensions.js');
const migration=read('supabase/migrations/202607270093_accounting_labor_item_type.sql');

function check(condition,message){if(!condition)throw new Error(message);}

check(/service:\s*["']Main d’œuvre["']/.test(catalog),'Le catalogue n’affiche pas Main d’œuvre.');
check(/\['service','Main d’œuvre','706000'\]/.test(accounting),'Le compte 706000 de Main d’œuvre manque.');
check(editor.includes('<option value="service">Main d’œuvre</option>'),'Le type Main d’œuvre manque dans la création rapide des documents.');
for(const label of ['Article','Main d’œuvre','Abonnement','Frais'])check(catalog.includes(label),`Le type ${label} manque du catalogue.`);
for(const obsolete of ['<option value="package"','<option value="discount"']){
  check(!catalog.includes(obsolete)&&!editor.includes(obsolete),`Le pseudo-type ${obsolete} est encore sélectionnable.`);
}
check(migration.includes("('product','707000'),('service','706000'),('subscription','706000'),('fee','708000')"),'Les comptes par défaut sont incorrects.');
check(migration.includes("check(item_type in('product','service','subscription','fee'))"),'La base autorise encore des pseudo-types.');
check(migration.includes('canonical_catalog_item_type'),'La normalisation API du type Main d’œuvre manque.');
check(migration.includes("lower(scope_value) in('package','pack','kit','discount','remise','comment','commentaire')"),'Les anciens paramètres ne sont pas nettoyés.');
check(catalog.includes('canonicalItemType(row.type || "Article")'),'L’import ne normalise pas les types métier.');
check(catalog.includes('typeLabels[item.item_type] || item.item_type'),'L’export catalogue ne restitue pas le libellé métier.');

console.log(JSON.stringify({ok:true,types:['Article','Main d’œuvre','Abonnement','Frais'],labor_account:'706000'}));
