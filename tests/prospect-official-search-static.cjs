const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const crm = read("assets/js/modules/erp/erp-crm-command-center.js");
const crmEnterprise = read("assets/js/modules/erp/erp-crm-enterprise.js");
const clients = read("assets/js/modules/erp/erp-clients.js");
const help = read("assets/js/modules/erp/erp-help-support.js");
const migration = read(
  "supabase/migrations/202607290116_prospect_official_company_and_person_fields.sql",
);
const updateMigration = read(
  "supabase/migrations/202607290117_update_crm_prospect_company_person_fields.sql",
);

assert.match(crm, /Recherche officielle INPI \/ INSEE/);
assert.match(crm, /api\(\)\.invoke\('company-search',\{query,perPage:7\}\)/);
assert.match(crm, /data-prospect-company/);
assert.match(crm, /data-prospect-person/);
assert.match(crm, /function toggleProspectKind\(kind\)/);
assert.match(crm, /legal_name:professional\?raw\.legal_name/);
assert.match(crm, /siret:professional\?raw\.siret\|\|null:null/);
assert.match(crm, /civility:professional\?null:raw\.civility/);
assert.match(crm, /data-training-official-company/);

// erp-crm-enterprise is loaded after the command center and overrides the
// creation handler. It must expose the same professional/individual workflow.
assert.match(crmEnterprise, /Création client \/ prospect/);
assert.match(crmEnterprise, /Recherche officielle INPI \/ INSEE/);
assert.match(crmEnterprise, /id="crm-prospect-kind-company"/);
assert.match(crmEnterprise, /data-prospect-company/);
assert.match(crmEnterprise, /data-prospect-person/);
assert.match(crmEnterprise, /crm\.toggleProspectKind\(kind\)/);
assert.match(crmEnterprise, /legal_name:professional\?String\(raw\.legal_name/);
assert.match(crmEnterprise, /id="crm-prospect-submit"/);

assert.match(clients, /Recherche INPI/);
assert.match(clients, /invoke\("company-search", \{ query, perPage: 7 \}\)/);
assert.match(clients, /form\.elements\.legal_name\.required = professional/);
assert.match(clients, /legal_name: professional \? raw\.legal_name/);
assert.match(clients, /siret: professional \? raw\.siret \|\| null : null/);

assert.match(migration, /legal_form,civility,first_name,last_name/);
assert.match(migration, /case when kind_value='company' then legal_name_value else null end/);
assert.match(migration, /case when kind_value='person' then nullif\(trim\(target_payload->>'civility'\),''\) else null end/);
assert.match(migration, /crm_prospect_person_name_required/);
assert.match(updateMigration, /create or replace function public\.update_crm_prospect/);
assert.match(updateMigration, /legal_form=case when kind_value='company'/);
assert.match(updateMigration, /ape_code=case when kind_value='company'/);
assert.match(updateMigration, /crm_prospect_person_name_required/);

assert.match(help, /id:'prospect',title:'Créer et qualifier un prospect'/);
assert.match(help, /selector:'#crm-prospect-company-search'/);
assert.match(help, /selector:'#crm-prospect-submit'/);
assert.match(help, /saveOpportunity\|saveProspect\|saveQuickParty/);
assert.doesNotMatch(help, /prospect:\[\['input','Entreprise','Société Démo'/);

console.log("prospect-official-search-static: ok");
