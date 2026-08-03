const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const modern = fs.readFileSync(path.join(root, 'assets/css/modern-erp.css'), 'utf8');
const premium = fs.readFileSync(path.join(root, 'assets/css/piloz-premium.css'), 'utf8');
const navigation = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-modern.js'), 'utf8');
const commercialNavigation = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-commercial-v2.js'), 'utf8');
const accessControl = fs.readFileSync(path.join(root, 'assets/js/modules/erp/erp-access-control.js'), 'utf8');

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function rule(css, selector) {
  const match = css.match(new RegExp(`${escapeRegExp(selector)}\\s*\\{([^}]*)\\}`));
  return match ? match[1].replace(/\s+/g, '') : '';
}

const modernMain = rule(modern, '.app.modern-subnav-open .main');
const modernEditor = rule(modern, '.modern-subnav-open .erp-editor');
const premiumMain = rule(premium, '.app.modern-subnav-open .main');
const premiumEditor = rule(premium, '.modern-subnav-open .erp-editor');
const rail = rule(modern, '.rail');
const documentEditor = rule(modern, '.document-v2');
const railZ = Number(rail.match(/z-index:(\d+)/)?.[1] || 0);
const documentZ = Number(documentEditor.match(/z-index:(\d+)/)?.[1] || 0);

const checks = [
  ['la page principale ne se decale plus', modernMain.includes('margin-left:0') && modernMain.includes('width:calc(100%-var(--modern-rail-width))')],
  ['les editeurs ne se decalent plus', modernEditor.includes('left:var(--modern-rail-width)!important')],
  ['le theme premium conserve la superposition', premiumMain.includes('margin-left:0') && premiumMain.includes('width:calc(100%-var(--modern-rail-width))') && premiumEditor.includes('left:var(--modern-rail-width)!important')],
  ['le sous-menu passe devant les documents plein ecran', railZ > documentZ && documentZ > 0],
  ['aucun ancien decalage de 232 ou 244 px', !modernMain.includes('232px') && !modernEditor.includes('232px') && !premiumMain.includes('244px') && !premiumEditor.includes('244px')],
  ['un clic exterieur ferme le sous-menu sans rerendu global', navigation.includes("document.addEventListener('pointerdown',dismissSecondaryOutside,true)") && navigation.includes("document.addEventListener('click',dismissSecondaryOutside,true)") && navigation.includes("target.closest('.modern-secondary-panel,.modern-primary-item')") && navigation.includes('function safeRemoveSecondaryNode(node)') && navigation.includes("document.querySelectorAll('.modern-secondary-panel,.modern-subnav-backdrop,.modern-navigation-overlay,[data-modern-secondary-panel]').forEach(safeRemoveSecondaryNode)")],
  ['une destination du sous-menu ouvre la page puis ferme le panneau', navigation.includes("function selectSecondary(path){closeSecondary();app().go(path);}") && navigation.includes("onclick=\"PilozModern.selectSecondary('${path}')\"")],
  ['les menus commerciaux enrichis utilisent la meme fermeture', commercialNavigation.includes("onclick=\"PilozModern.selectSecondary('${itemPath}')\"")],
  ['les permissions restent appliquees aux destinations du sous-menu', navigation.includes('data-route="${path}"') && commercialNavigation.includes('data-route="${itemPath}"') && accessControl.includes('button.dataset.route||')],
];

const failed = checks.filter(([, ok]) => !ok);
if (failed.length) {
  for (const [label] of failed) console.error(`FAIL ${label}`);
  process.exit(1);
}

for (const [label] of checks) console.log(`OK ${label}`);
