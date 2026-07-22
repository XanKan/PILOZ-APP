(function(global){
  const VERSION=Object.freeze({application:'2026.07-compliance',validator:'invoice-validator-v1',calculation:'financial-v1',canonicalization:'json-c14n-draft-v1'});
  const POW10=[1n,10n,100n,1000n,10000n,100000n,1000000n,10000000n,100000000n,1000000000n,10000000000n];
  function scaled(value,scale){
    const input=String(value??0).trim().replace(',','.');
    if(!/^-?\d+(?:\.\d+)?$/.test(input))throw new TypeError('invalid_decimal');
    const negative=input.startsWith('-'),parts=input.replace('-','').split('.'),fraction=(parts[1]||'').padEnd(scale,'0').slice(0,scale);
    return(negative?-1n:1n)*(BigInt(parts[0]||0)*POW10[scale]+BigInt(fraction||0));
  }
  function roundDivide(value,divisor){const negative=value<0n,absolute=negative?-value:value,result=(absolute+divisor/2n)/divisor;return negative?-result:result;}
  function minor(value){return scaled(value,2);}
  function decimal(minorValue){return Number(minorValue)/100;}
  function calculateLine(line={}){
    const quantity=scaled(line.quantity??0,4),unitPrice=scaled(line.unit_price??0,4),discount=scaled(line.discount_rate??0,2),tax=scaled(line.tax_rate??0,2);
    if(quantity<0n||unitPrice<0n||discount<0n||discount>10000n||tax<0n||tax>10000n)throw new RangeError('invalid_financial_value');
    const ht=roundDivide(quantity*unitPrice*(10000n-discount),10000000000n),vat=roundDivide(ht*tax,10000n);
    return Object.freeze({htMinor:ht,taxMinor:vat,ttcMinor:ht+vat,ht:decimal(ht),tax:decimal(vat),ttc:decimal(ht+vat)});
  }
  function calculateDocument(lines=[],globalDiscountRate=0){
    let ht=0n,tax=0n,cost=0n;
    for(const line of lines){if(line.optional||!['item','free_item','discount'].includes(line.line_type||'item'))continue;const amount=calculateLine(line);ht+=amount.htMinor;tax+=amount.taxMinor;cost+=roundDivide(scaled(line.quantity??0,4)*scaled(line.unit_cost_snapshot??0,4),1000000n);}
    const discount=scaled(globalDiscountRate??0,2);if(discount<0n||discount>10000n)throw new RangeError('invalid_global_discount');
    ht=roundDivide(ht*(10000n-discount),10000n);tax=roundDivide(tax*(10000n-discount),10000n);
    return Object.freeze({totalCostMinor:cost,htMinor:ht,taxMinor:tax,ttcMinor:ht+tax,totalCost:decimal(cost),ht:decimal(ht),tax:decimal(tax),ttc:decimal(ht+tax),version:VERSION.calculation});
  }
  function resolveRequiredInvoiceMentions(context={}){
    const result=[];
    if(context.issuer?.subject_to_vat===false)result.push({code:'vat_exemption',configuredText:context.settings?.legal_notice||'',requiresLegalValidation:!context.settings?.legal_notice});
    if(context.issuer?.vat_on_debits)result.push({code:'vat_on_debits',configuredText:'',requiresLegalValidation:true});
    if(context.document?.document_type==='credit_note')result.push({code:'credit_note_reference',sourceNumber:context.sourceDocument?.number||'',requiresLegalValidation:!context.sourceDocument?.number});
    if(context.document?.document_type==='deposit_invoice')result.push({code:'deposit_invoice',configuredText:'',requiresLegalValidation:true});
    result.push({code:'payment_terms',configuredText:context.document?.payment_terms||'',requiresLegalValidation:!context.document?.payment_terms});
    return result;
  }
  function validateInvoice(context={}){
    const errors=[],warnings=[],document=context.document||{},issuer=context.issuer||{},client=context.client||{},lines=context.lines||[];
    if(!issuer.legal_name)errors.push({code:'issuer_legal_name_required',field:'issuer.legal_name'});
    if(!/^\d{14}$/.test(String(issuer.siret||'')))errors.push({code:'issuer_siret_required',field:'issuer.siret'});
    if(!client.id)errors.push({code:'client_required',field:'client_id'});
    if(!document.issue_date)errors.push({code:'issue_date_required',field:'issue_date'});
    if(!/^[A-Z]{3}$/.test(String(document.currency||'')))errors.push({code:'currency_invalid',field:'currency'});
    if(!lines.some(line=>!line.optional&&['item','free_item','discount'].includes(line.line_type||'item')))errors.push({code:'document_lines_required',field:'lines'});
    if(!document.sale_type)warnings.push({code:'operation_category_to_confirm',field:'sale_type'});
    const mentions=resolveRequiredInvoiceMentions(context);if(mentions.some(item=>item.requiresLegalValidation))warnings.push({code:'legal_mentions_require_validation',field:'legal_mentions'});
    return Object.freeze({valid:errors.length===0,errors,warnings,mentions,validatorVersion:VERSION.validator});
  }
  global.PilozFiscalDomain=Object.freeze({VERSION,scaled,minor,decimal,calculateLine,calculateDocument,resolveRequiredInvoiceMentions,validateInvoice});
})(window);
