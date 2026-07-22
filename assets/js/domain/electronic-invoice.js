(function(global){
  const VERSION=Object.freeze({canonical:'1.0',rules:'canonical-business-rules-v1'});
  const profileFormats=new Set(['ubl','cii','facturx']);
  const object=value=>value&&typeof value==='object'&&!Array.isArray(value)?value:{};
  const array=value=>Array.isArray(value)?value:[];
  const value=(source,...keys)=>{for(const key of keys)if(source?.[key]!==undefined&&source?.[key]!==null&&source?.[key]!=='')return source[key];return null;};
  const decimalString=input=>{
    const source=String(input??0).trim().replace(',','.');
    if(!/^-?\d+(?:\.\d+)?$/.test(source))throw new TypeError('invalid_decimal');
    const [whole,fraction='']=source.split('.');return `${whole}.${fraction.padEnd(2,'0').slice(0,4)}`.replace(/\.0+$/,'');
  };
  function party(source={},extra={}){
    return Object.freeze({
      id:value(source,'id'),kind:value(source,'kind'),legalName:value(source,'legal_name','legalName'),tradeName:value(source,'trade_name','tradeName'),
      firstName:value(source,'first_name','firstName'),lastName:value(source,'last_name','lastName'),siren:value(source,'siren'),siret:value(source,'siret'),
      vatNumber:value(source,'vat_number','vatNumber'),email:value(source,'email'),electronicBillingEmail:value(extra,'electronic_billing_email','electronicBillingEmail'),
      routingIdentifier:value(extra,'routing_identifier','electronic_routing_identifier','routingIdentifier'),routingScheme:value(extra,'routing_scheme','electronic_routing_scheme','routingScheme'),
      category:value(extra,'category','customer_category')||'unknown',address:Object.freeze({line1:value(source,'address_line1','address_line_1'),line2:value(source,'address_line2','address_line_2'),postalCode:value(source,'postal_code','postalCode'),city:value(source,'city'),countryCode:value(source,'country_code','countryCode')})
    });
  }
  function line(source,index){
    return Object.freeze({id:value(source,'id')||`line-${index+1}`,position:Number(value(source,'position')??index+1),type:value(source,'line_type','type')||'item',reference:value(source,'reference'),name:value(source,'name'),description:value(source,'description'),quantity:decimalString(value(source,'quantity')??0),unit:value(source,'unit'),unitPriceExclTax:decimalString(value(source,'unit_price','unitPrice')??0),discountRate:decimalString(value(source,'discount_rate','discountRate')??0),tax:Object.freeze({rate:decimalString(value(source,'tax_rate','taxRate')??0),category:value(source,'tax_category','taxCategory')}),totals:Object.freeze({exclTax:decimalString(value(source,'total_excl_tax','totalExclTax')??0),tax:decimalString(value(source,'total_tax','totalTax')??0),inclTax:decimalString(value(source,'total_incl_tax','totalInclTax')??0)}),optional:!!source.optional});
  }
  function build(snapshot={},context={}){
    const document=object(snapshot.document),issuer=object(snapshot.issuer),customer=object(snapshot.client),settings=object(snapshot.document_settings),overrides=object(context.document);
    const lines=array(snapshot.lines).map(line);
    return Object.freeze({format:'piloz-canonical-invoice',formatVersion:VERSION.canonical,supplier:party(issuer,{...settings,...object(context.supplier)}),customer:party(customer,object(context.customer)),invoice:Object.freeze({id:value(document,'id'),number:value(document,'number'),type:value(document,'document_type'),issueDate:value(document,'issue_date'),dueDate:value(document,'due_date'),supplyDate:value(overrides,'supply_date','supplyDate'),currency:value(document,'currency')||'EUR',language:value(document,'language')||'fr',operationCategory:value(overrides,'operation_category','operationCategory')||value(document,'sale_type'),subject:value(document,'subject'),contractReference:value(overrides,'contract_reference','contractReference'),purchaseOrderReference:value(overrides,'purchase_order_reference','purchaseOrderReference')||value(document,'client_reference')}),lines,taxBreakdown:array(context.taxBreakdown),totals:Object.freeze({exclTax:decimalString(value(document,'total_excl_tax')??0),tax:decimalString(value(document,'total_tax')??0),inclTax:decimalString(value(document,'total_incl_tax')??0),paid:decimalString(context.paid??0),payable:decimalString(context.payable??value(document,'total_incl_tax')??0)}),payment:Object.freeze({terms:value(document,'payment_terms'),method:value(document,'payment_method'),entries:array(context.payments)}),references:array(context.references),delivery:Object.freeze(object(context.delivery)),reporting:Object.freeze({...object(context.reporting),classificationStatus:'requires_rule_engine_validation'}),lifecycle:Object.freeze({status:value(overrides,'electronic_invoice_status')||'not_prepared',finalizedAt:value(document,'finalized_at')}),source:Object.freeze({snapshotId:value(context,'snapshotId')||value(document,'snapshot_id'),snapshotHash:value(context,'snapshotHash'),applicationVersion:value(document,'application_version'),schemaVersion:value(document,'database_schema_version'),calculationVersion:value(document,'calculation_version'),pdfGeneratorVersion:value(document,'pdf_generator_version'),electronicFormatVersion:value(document,'electronic_format_version'),fiscalPolicyVersion:value(document,'fiscal_policy_version')})});
  }
  function validate(invoice){
    const errors=[],warnings=[];
    const required=(condition,code,field)=>{if(!condition)errors.push({code,field});};
    required(invoice?.format==='piloz-canonical-invoice','canonical_format_invalid','format');
    required(invoice?.invoice?.number,'invoice_number_required','invoice.number');
    required(invoice?.invoice?.issueDate,'issue_date_required','invoice.issueDate');
    required(/^[A-Z]{3}$/.test(invoice?.invoice?.currency||''),'currency_invalid','invoice.currency');
    required(invoice?.supplier?.legalName||invoice?.supplier?.tradeName,'supplier_name_required','supplier');
    required(invoice?.supplier?.siren||invoice?.supplier?.siret,'supplier_identifier_required','supplier.siren');
    required(invoice?.customer?.legalName||invoice?.customer?.lastName,'customer_name_required','customer');
    required(array(invoice?.lines).some(item=>!item.optional),'invoice_line_required','lines');
    if(invoice?.customer?.category==='unknown')warnings.push({code:'customer_category_to_confirm',field:'customer.category'});
    if(!invoice?.invoice?.operationCategory)warnings.push({code:'operation_category_to_confirm',field:'invoice.operationCategory'});
    if(!invoice?.customer?.routingIdentifier)warnings.push({code:'routing_identifier_missing',field:'customer.routingIdentifier'});
    return Object.freeze({valid:errors.length===0,errors,warnings,validatorVersion:VERSION.rules});
  }
  function formatReadiness(format,profiles=[]){
    if(!profileFormats.has(format))return Object.freeze({ready:false,code:'unsupported_electronic_format',format});
    const profile=profiles.find(item=>item.format===format&&item.validation_status==='verified'&&item.xsd_storage_path);
    return profile?Object.freeze({ready:true,format,profile}):Object.freeze({ready:false,format,code:'official_profile_not_configured',externalValidationRequired:true});
  }
  function exportStructured(format,invoice,profiles=[]){
    const readiness=formatReadiness(format,profiles);
    if(!readiness.ready){const error=new Error('Le profil officiel XSD/Schematron n’est pas installé ou vérifié.');error.code=readiness.code;error.format=format;throw error;}
    const error=new Error('L’adaptateur serveur validé pour ce profil n’est pas encore installé.');error.code='validated_server_adapter_not_installed';error.format=format;throw error;
  }
  global.PilozElectronicInvoice=Object.freeze({VERSION,build,validate,formatReadiness,exportStructured,decimalString});
})(window);
