const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const billing=read('supabase/functions/stripe-billing/index.ts');
const publicCheckout=read('supabase/functions/stripe-public-checkout/index.ts');
const webhook=read('supabase/functions/stripe-webhook/index.ts');
const frontend=read('assets/js/modules/erp/erp-modern.js');
const config=read('supabase/config.toml');
const billingMigration=read('supabase/migrations/202607240057_stripe_billing.sql');
const trialMigration=read('supabase/migrations/202607240058_stripe_trial_checkout_and_billing_profile.sql');
const checks={
 secret_server_only:billing.includes('Deno.env.get("STRIPE_SECRET_KEY")')&&publicCheckout.includes('Deno.env.get("STRIPE_SECRET_KEY")')&&webhook.includes('Deno.env.get("STRIPE_WEBHOOK_SECRET")')&&!frontend.includes('STRIPE_SECRET_KEY')&&!frontend.includes('STRIPE_WEBHOOK_SECRET'),
 raw_signed_webhook:webhook.includes('const rawBody=await req.text()')&&webhook.includes('constructEventAsync(rawBody,signature,webhookSecret'),
 webhook_public_but_signed:/\[functions\.stripe-webhook\][\s\S]*verify_jwt\s*=\s*false/.test(config)&&webhook.includes('stripe-signature'),
 public_checkout_declared:/\[functions\.stripe-public-checkout\][\s\S]*verify_jwt\s*=\s*false/.test(config)&&publicCheckout.includes('origins.has(origin)'),
 idempotent_events:billingMigration.includes('event_id text primary key')&&webhook.includes('duplicate:true'),
 checkout_and_portal:billing.includes('checkout.sessions.create')&&billing.includes('billingPortal.sessions.create'),
 card_required_during_trial:publicCheckout.includes('payment_method_collection:"always"')&&publicCheckout.includes('trial_period_days:14'),
 plan_update_confirmed_by_stripe:billing.includes('subscription_update_confirm')&&billing.includes('items:[{id:item.id,price:mapping.external_price_id'),
 secure_checkout_claim:trialMigration.includes('claim_token_hash text not null unique')&&trialMigration.includes('enable row level security')&&publicCheckout.includes('claimHash=await hashHex(claimToken)'),
 browser_plan_change_blocked:trialMigration.includes('revoke execute on function public.choose_plan(uuid,text,text) from public,anon,authenticated'),
 company_authorization:billing.includes('["owner","admin"].includes(member.role)'),
 customer_billing_rls:billingMigration.includes('platform_billing_invoices_company_select')&&billingMigration.includes("array['owner','admin']"),
 masked_payment_only:billingMigration.includes('payment_method_last4')&&!billingMigration.includes('card_number')&&!trialMigration.includes('card_number'),
 billing_profile_synced:trialMigration.includes('billing_address_line1')&&trialMigration.includes('invoice_pdf_url')&&webhook.includes('billing_tax_id:profile?.taxId'),
 invoice_payment_sync:webhook.includes('platform_billing_invoices')&&webhook.includes('platform_billing_payments')&&webhook.includes('platform_billing_refunds'),
 friendly_unconfigured_state:billing.includes('stripe_not_configured')&&billing.includes('configured:false')
};
const failed=Object.entries(checks).filter(([,ok])=>!ok).map(([name])=>name);
console.log(JSON.stringify({ok:failed.length===0,checks,failed}));
if(failed.length)process.exitCode=1;
