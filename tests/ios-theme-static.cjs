const fs = require('node:fs');

const html = fs.readFileSync('index.html', 'utf8');
const css = fs.readFileSync('assets/css/piloz-ios.css', 'utf8');

const checks = {
  theme_loaded_after_feature_styles:
    html.indexOf('assets/css/piloz-ios.css?v=20260729.3') > html.indexOf('assets/css/accounting-extensions.css'),
  dark_navigation_present:
    css.includes('.rail{') && css.includes('linear-gradient(180deg,#0c2947 0%,#071b31 52%,#061426 100%)'),
  shared_ios_controls_present:
    css.includes('.btn,') && css.includes('.crm-button,') && css.includes('.access-btn,') && css.includes('border-radius:13px!important'),
  shared_frosted_surfaces_present:
    css.includes('.settings-overview-card,.company-summary-card,.company-subnav,') && css.includes('.ops-extension-card,.ops-settings-dashboard>button,.ops-terms-card,') && css.includes('backdrop-filter:blur(18px) saturate(125%)'),
  dashboard_direction_present:
    css.includes('.cockpit-hero{') && css.includes('.cockpit-kpi,') && css.includes('.cockpit-chart-panel,'),
  accounting_and_access_covered:
    css.includes('.ops-export-table thead th{') && css.includes('.access-role-grid{gap:18px!important}'),
  documents_keep_white_print_surface:
    css.includes('@media print{') && css.includes('.erp-paper,.document-v2-paper{border-radius:0!important;box-shadow:none!important}'),
  reduced_motion_supported:
    css.includes('@media(prefers-reduced-motion:reduce)'),
};

console.log(JSON.stringify(checks, null, 2));
if (Object.values(checks).some((value) => !value)) process.exit(1);
