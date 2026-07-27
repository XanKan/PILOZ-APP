const fs=require('node:fs');
const modern=fs.readFileSync('assets/js/modules/erp/erp-modern.js','utf8');
const app=fs.readFileSync('assets/js/modules/erp/erp-app.js','utf8');
const accounting=fs.readFileSync('assets/js/modules/erp/erp-accounting-extensions.js','utf8');
const commercial=fs.readFileSync('assets/js/modules/erp/erp-commercial-v2.js','utf8');
const clients=fs.readFileSync('assets/js/modules/erp/erp-clients.js','utf8');

const checks={
  no_sales_terms_settings_tab:!modern.match(/settings:\{[^\n]+settings\/sales-terms/),
  sales_terms_grouped_in_templates:modern.includes("['settings/templates','Modèles de documents','Thèmes, logos, couleurs, colonnes, pieds de page et CGV."),
  sales_terms_back_button:accounting.includes("button('Retour aux paramètres',\"PilozApp.go('settings/overview')\""),
  accounting_submenu_complete:['Exercices fiscaux','Journaux','Tiers','Acomptes','Ventes','Achats','TVA','Comptes financiers'].every(label=>modern.includes(`,'${label}']`)),
  complementary_accounts_hidden:!modern.includes("['accounting/settings/complementary','Comptes complémentaires']")&&!app.includes("'accounting/settings/complementary':'accounting-settings'"),
  accounting_nested_routes:['exercises','journals','tiers','deposits','sales','purchases','vat','financial'].every(route=>app.includes(`'accounting/settings/${route}':'accounting-settings'`)),
  accounting_route_selects_tab:accounting.includes("currentPath.startsWith('accounting/settings/')")&&accounting.includes("app().go(`accounting/settings/${tab}`)"),
  deposit_example_updates_immediately:accounting.includes('onchange="PilozOps.updateDepositExample()"')&&accounting.includes('oninput="PilozOps.updateDepositExample()"')&&accounting.includes('function updateDepositExample()'),
  deposit_examples_follow_selected_method:accounting.includes("direct=method==='direct'")&&accounting.includes("<td>${esc(vatSuspense)}</td><td>Débit</td><td>100,00</td>")&&accounting.includes("<td>${esc(vatSales)}</td><td>Crédit</td><td>100,00</td>"),
  sales_accounts_use_current_editable_defaults:accounting.includes("['product','Article','707000']")&&accounting.includes("['service','Main d’œuvre','706000']")&&accounting.includes("['subscription','Abonnement','706000']")&&accounting.includes("['fee','Frais','708000']")&&accounting.includes('data-direction="sale" data-scope-type="item_type"')&&accounting.includes("api().insert('accounting_account_mappings'"),
  payment_accounts_editable_with_512100_default:accounting.includes("row?.financial_account_code||'512100'")&&accounting.includes('data-payment-method=')&&accounting.includes("api().insert('accounting_payment_method_mappings'"),
  accounting_shortcut_not_redirected:commercial.includes("accounting:'accounting/payments'"),
  tiers_default_to_individualized_accounts:accounting.includes("settings.customer_account_mode||'individualized'")&&accounting.includes('function individualizedCustomerAccount')&&accounting.includes("individualizedCustomerAccount('Dupont Martin')")&&accounting.includes('Compte client individualisé dans CompteNum')&&accounting.includes('max="10"')&&!accounting.includes('ops-third-party-identifier'),
  tiers_hide_generic_prefix_fields:!accounting.includes("['customer_auxiliary_prefix','Préfixe auxiliaire client']")&&!accounting.includes("['supplier_auxiliary_prefix','Préfixe auxiliaire fournisseur']"),
  client_profile_persists_individual_account:clients.includes('<h2>Compte comptable client</h2>')&&clients.includes('placeholder="Ex. 411SOLUNEO"')&&clients.includes("assign_client_individual_account"),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
