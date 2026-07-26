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
  accounting_submenu_complete:['Exercices fiscaux','Journaux','Tiers','Acomptes','Ventes','Achats','TVA','Comptes financiers','Comptes complémentaires'].every(label=>modern.includes(`,'${label}']`)),
  accounting_nested_routes:['exercises','journals','tiers','deposits','sales','purchases','vat','financial','complementary'].every(route=>app.includes(`'accounting/settings/${route}':'accounting-settings'`)),
  accounting_route_selects_tab:accounting.includes("currentPath.startsWith('accounting/settings/')")&&accounting.includes("app().go(`accounting/settings/${tab}`)"),
  accounting_shortcut_not_redirected:commercial.includes("accounting:'accounting/payments'"),
  tiers_use_individual_identifiers:accounting.includes('Identifiant client')&&accounting.includes('Identifiant fournisseur')&&accounting.includes('ops-third-party-identifier'),
  tiers_hide_generic_prefix_fields:!accounting.includes("['customer_auxiliary_prefix','Préfixe auxiliaire client']")&&!accounting.includes("['supplier_auxiliary_prefix','Préfixe auxiliaire fournisseur']"),
  client_profile_uses_real_identifier:clients.includes('<h2>Identifiant client</h2>')&&clients.includes('placeholder="Ex. DUPONT"'),
};

console.log(JSON.stringify(checks,null,2));
if(Object.values(checks).some(value=>!value))process.exit(1);
