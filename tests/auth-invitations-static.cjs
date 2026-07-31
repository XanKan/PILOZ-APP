const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = relativePath => fs.readFileSync(path.join(root, relativePath), 'utf8');
const app = read('index.html');
const config = read('supabase/config.toml');
const platformAdmin = read('supabase/functions/platform-admin-api/index.ts');
const companyAccess = read('supabase/functions/company-access/index.ts');
const accessUi = read('assets/js/modules/erp/erp-access-control.js');
const inviteTemplate = read('supabase/templates/invite.html');

const checks = {
  invite_opens_password_creation: app.includes("['recovery','invite'].includes(hp.get('type'))"),
  production_site_url: /site_url\s*=\s*"https:\/\/app\.piloz\.fr"/.test(config),
  app_redirect_allowed: config.includes('"https://app.piloz.fr/**"'),
  admin_redirect_allowed: config.includes('"https://admin.piloz.fr/**"'),
  platform_owner_invite_uses_production: platformAdmin.includes('redirectTo:"https://app.piloz.fr/?mode=login"'),
  company_invite_uses_production: companyAccess.includes('redirectTo:"https://app.piloz.fr/?mode=login"'),
  activation_email_can_be_resent: platformAdmin.includes('action==="users.activation_email"') && platformAdmin.includes('target_action:"user.activation_email_resent"'),
  no_localhost_auth_redirect: !/(?:site_url\s*=\s*|redirectTo:)[^\r\n]*localhost/.test(config + platformAdmin + companyAccess),
  invite_template_is_versioned: config.includes('[auth.email.template.invite]') && config.includes('content_path = "./supabase/templates/invite.html"'),
  invite_subject_is_french: config.includes('subject = "Vous êtes invité(e) à rejoindre PILOZ"'),
  invite_template_uses_confirmation_url: (inviteTemplate.match(/\{\{ \.ConfirmationURL \}\}/g)||[]).length >= 2,
  invite_template_is_branded: inviteTemplate.includes('PILOZ') && inviteTemplate.includes('Accepter l’invitation'),
  spam_delivery_guidance_is_visible: accessUi.includes('courriers indésirables (spams)') && companyAccess.includes('courriers indésirables (spams)')
};

const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([name]) => name);
console.log(JSON.stringify({ ok: failed.length === 0, checks, failed }, null, 2));
if (failed.length) process.exitCode = 1;
