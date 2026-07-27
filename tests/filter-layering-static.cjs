const fs = require('node:fs');

const css = fs.readFileSync('assets/css/piloz-premium.css', 'utf8');

const checks = {
  document_filters_have_foreground_layer:
    css.includes('.modern-filters,') && css.includes('.document-viewer-filter-panel{\n  position:relative;\n  z-index:40;\n  overflow:visible;'),
  every_workspace_filter_surface_is_covered:
    ['.commercial-filters,', '.client-toolbar,', '.client-advanced-filters,', '.catalog-controls,', '.catalog-filters,', '.crm-toolbar,', '.ops-toolbar,'].every((selector) => css.includes(selector)),
  result_tables_stay_on_base_layer:
    css.includes('.modern-table-shell,') && css.includes('.document-viewer-list-scroll{\n  position:relative;\n  z-index:0;'),
  open_filter_fields_own_a_local_layer:
    css.includes('.modern-date-range:has(.modern-date-range-popover),') && css.includes('.document-viewer-client-filter:has(.document-viewer-client-suggestions){\n  z-index:90;'),
  popovers_are_above_filter_surfaces:
    css.includes('.modern-date-range-popover,') && css.includes('.document-viewer-client-suggestions{\n  z-index:100;'),
};

console.log(JSON.stringify(checks, null, 2));
if (Object.values(checks).some((value) => !value)) process.exit(1);
