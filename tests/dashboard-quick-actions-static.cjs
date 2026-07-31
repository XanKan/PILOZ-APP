const fs = require('node:fs');

const css = fs.readFileSync('assets/css/dashboard-cockpit.css', 'utf8');
const js = fs.readFileSync('assets/js/modules/erp/erp-dashboard-cockpit.js', 'utf8');

const checks = {
  hero_allows_the_menu_to_escape:
    css.includes('.cockpit-shell .cockpit-hero{position:relative;z-index:30;') &&
    css.includes('overflow:visible;'),
  hero_decoration_stays_clipped:
    css.includes('.cockpit-hero-decoration{position:absolute;z-index:0;inset:0;overflow:hidden;') &&
    js.includes('class="cockpit-hero-decoration" aria-hidden="true"'),
  open_menu_owns_the_foreground:
    css.includes('.cockpit-quick-actions details[open]{z-index:80}') &&
    css.includes('.cockpit-quick-actions details>div{z-index:90;'),
  long_menu_remains_usable:
    css.includes('max-height:min(420px,calc(100vh - 190px));') &&
    css.includes('min-width:240px;overflow:auto;'),
  filter_bar_stays_below_the_menu:
    css.includes('.cockpit-filterbar{position:relative;z-index:1;'),
  menu_closes_outside_and_with_escape:
    js.includes("document.querySelectorAll('.cockpit-quick-actions details[open]')") &&
    js.includes("event.key!=='Escape'") &&
    js.includes("document.addEventListener('click',closeQuickActions)") &&
    js.includes("document.addEventListener('keydown',closeQuickActions)"),
};

console.log(JSON.stringify(checks, null, 2));
if (Object.values(checks).some((value) => !value)) process.exit(1);
