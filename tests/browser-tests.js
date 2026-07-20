(function(){
 const tests=[],test=(name,fn)=>tests.push([name,fn]),equal=(actual,expected)=>{if(actual!==expected)throw new Error(`attendu ${expected}, obtenu ${actual}`);};
 test('calcul ligne HT',()=>equal(PilozCalculations.line({quantity:2,unit_price:100,tax_rate:20}).ht,200));
 test('calcul ligne TVA',()=>equal(PilozCalculations.line({quantity:2,unit_price:100,tax_rate:20}).tax,40));
 test('calcul ligne TTC',()=>equal(PilozCalculations.line({quantity:2,unit_price:100,tax_rate:20}).ttc,240));
 test('remise de ligne',()=>equal(PilozCalculations.line({quantity:2,unit_price:100,discount_rate:10}).ht,180));
 test('marge brute',()=>equal(PilozCalculations.line({quantity:2,unit_cost_snapshot:60,unit_price:100}).margin,80));
 test('taux de marge sans division par zéro',()=>equal(PilozCalculations.line({quantity:1,unit_cost_snapshot:0,unit_price:100}).marginRate,null));
 test('taux de marque',()=>equal(PilozCalculations.line({quantity:1,unit_cost_snapshot:60,unit_price:100}).markupRate,40));
 test('remise globale',()=>equal(PilozCalculations.document([{quantity:1,unit_price:100,tax_rate:20}],10).ttc,108));
 test('option exclue des totaux',()=>equal(PilozCalculations.document([{quantity:1,unit_price:100},{quantity:1,unit_price:50,optional:true}]).ht,100));
 test('remise plafonnée à 100 %',()=>equal(PilozCalculations.line({quantity:1,unit_price:100,discount_rate:250}).ht,0));
 test('remise négative ramenée à zéro',()=>equal(PilozCalculations.line({quantity:1,unit_price:100,discount_rate:-20}).ht,100));
 test('arrondi monétaire déterministe',()=>equal(PilozCalculations.line({quantity:3,unit_price:0.1,tax_rate:20}).ttc,0.36));
 test('normalisation téléphone FR',()=>equal(PilozCalculations.e164('06 12 34 56 78','FR'),'+33612345678'));
 test('rejet téléphone invalide',()=>equal(PilozCalculations.e164('123','FR'),null));
 test('SIREN valide',()=>equal(PilozCalculations.validSiren('552 100 554'),true));
 test('SIREN invalide',()=>equal(PilozCalculations.validSiren('123 456 789'),false));
 let passed=0;const failures=[];for(const [name,fn] of tests){try{fn();passed++;}catch(error){failures.push(`${name}: ${error.message}`);}}
 const node=document.getElementById('results');node.dataset.status=failures.length?'failed':'passed';node.textContent=`${passed}/${tests.length} tests réussis${failures.length?' — '+failures.join(' | '):''}`;
})();
