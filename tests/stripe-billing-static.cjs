const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const billing=read('supabase/functions/stripe-billing/index.ts');
const webhook=read('supabase/functions/stripe-webhook/index.ts');
const frontend=read('assets/js/modules/erp/erp-modern.js');
const config=read('supabase/config.toml');
const migration=read('supabase/migrations/202607240057_stripe_billing.sql');
const checks={
 secret_server_only:billing.includes('Deno.env.get("STRIPE_SECRET_KEY")')&&webhook.includes('Deno.env.get("STRIPE_WEBHOOK_SECRET")')&&!frontend.includes('STRIPE_SECRET_KEY')&&!frontend.includes('STRIPE_WEBHOOK_SECRET'),
 raw_signed_webhook:webhook.includes('const rawBody=await req.text()')&&webhook.includes('constructEventAsync(rawBody,signature,webhookSecret'),
 webhook_public_but_signed:/\[functions\.stripe-webhook\][\s\S]*verify_jwt\s*=\s*false/.test(config)&&webhook.includes('stripe-signature'),
 idempotent_events:migration.includes('event_id text primary key')&&webhook.includes('duplicate:true'),
 checkout_and_portal:billing.includes('checkout.sessions.create')&&billing.includes('billingPortal.sessions.create'),
 no_duplicate_subscription:billing.includes('subscription.provider==="stripe"&&subscription.external_subscription_id'),
 company_authorization:billing.includes('["owner","admin"].includes(member.role)'),
 customer_billing_rls:migration.includes('platform_billing_invoices_company_select')&&migration.includes("array['owner','admin']"),
 masked_payment_only:migration.includes('payment_method_last4')&&!migration.includes('card_number'),
 invoice_payment_sync:webhook.includes('platform_billing_invoices')&&webhook.includes('platform_billing_payments')&&webhook.includes('platform_billing_refunds'),
 friendly_unconfigured_state:billing.includes('stripe_not_configured')&&billing.includes('configured:false')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
