const fs=require('node:fs');

const app=fs.readFileSync('assets/js/modules/erp/erp-app.js','utf8');
const editor=fs.readFileSync('assets/js/modules/erp/erp-document-editor-v2.js','utf8');
const checks=[
  ['régime non TVA booléen ou texte reconnu',app.includes("String(value).toLowerCase()==='false'")&&editor.includes("String(value).toLowerCase()==='false'")],
  ['toutes les lignes du brouillon sont remises à zéro',app.includes("(draft.lines||[]).forEach(line=>{line.tax_rate=0;})")&&editor.includes("d.lines.forEach(line=>{line.tax_rate=0;})")],
  ['options de sauvegarde conservées',app.includes('saveDocument=async function(...args)')&&app.includes('return saveDocumentBase(...args)')],
  ['motif réel propagé pendant la finalisation',editor.includes('finalizeCurrentDocument({throwOnError:true})')]
];
const failed=checks.filter(([,ok])=>!ok);
if(failed.length){console.error(JSON.stringify({ok:false,failed:failed.map(([name])=>name)}));process.exit(1);}
console.log(JSON.stringify({ok:true,checks:checks.length}));
