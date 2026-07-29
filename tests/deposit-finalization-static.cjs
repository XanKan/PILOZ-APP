const fs=require('node:fs');

const app=fs.readFileSync('assets/js/modules/erp/erp-app.js','utf8');
const editor=fs.readFileSync('assets/js/modules/erp/erp-document-editor-v2.js','utf8');
const viewer=fs.readFileSync('assets/js/modules/erp/erp-document-viewer-v2.js','utf8');
const chronology=fs.readFileSync('supabase/migrations/202607260066_legal_retention_audit_privacy.sql','utf8');
const checks=[
  ['régime non TVA booléen ou texte reconnu',app.includes("String(value).toLowerCase()==='false'")&&editor.includes("String(value).toLowerCase()==='false'")],
  ['toutes les lignes du brouillon sont remises à zéro',app.includes("(draft.lines||[]).forEach(line=>{line.tax_rate=0;})")&&editor.includes("d.lines.forEach(line=>{line.tax_rate=0;})")],
  ['options de sauvegarde conservées',app.includes('saveDocument=async function(...args)')&&app.includes('return saveDocumentBase(...args)')],
  ['motif réel propagé pendant la finalisation',editor.includes('finalizeCurrentDocument({throwOnError:true})')],
  ['consultation ouverte directement après finalisation',editor.includes('openFinalizedConsultation(result.id||saved.id)')&&editor.includes("if(invoiceTypes.has(d.document_type)&&locked(d)&&d.id){openFinalizedConsultation(d.id);return;}")],
  ['date de facture modifiable dans les deux parcours',editor.includes('name="issue_date" type="date" value="${issue}"${minAttr}')&&!editor.includes('name="issue_date" type="date" value="${today}" readonly')&&viewer.includes('id="document-viewer-finalize-form"')&&viewer.includes('name="issue_date" type="date" value="${defaults.issue}"${minAttr}')],
  ['première facture sans minimum puis minimum chronologique',editor.includes('minAttr=latest?')&&editor.includes('Première facture : vous pouvez choisir librement sa date.')&&viewer.includes('Première facture : vous pouvez choisir librement sa date.')],
  ['échéance recalée sur la date choisie',editor.includes("for(const name of['situation_date','due_date'])")&&viewer.includes("for(const name of['situation_date','due_date'])")],
  ['serveur autorise le même jour mais refuse une date antérieure',chronology.includes('new.issue_date<latest_issue_date')&&!chronology.includes('new.issue_date<=latest_issue_date')&&chronology.includes('invoice_issue_date_before_last_finalized')]
];
const failed=checks.filter(([,ok])=>!ok);
if(failed.length){console.error(JSON.stringify({ok:false,failed:failed.map(([name])=>name)}));process.exit(1);}
console.log(JSON.stringify({ok:true,checks:checks.length}));
