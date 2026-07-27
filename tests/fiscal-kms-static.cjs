const fs=require('fs');
const path=require('path');

const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const crypto=read('supabase/functions/_shared/fiscal-crypto.ts');
const exporter=read('supabase/functions/export-fiscal-archive/index.ts');
const migration=read('supabase/migrations/202607270095_fiscal_archive_kms_signatures.sql');

function check(condition,message){if(!condition)throw new Error(message);}

check(crypto.includes('MessageType: "DIGEST"'),'Le KMS ne signe pas explicitement une empreinte.');
check(crypto.includes('RSASSA_PSS_SHA_256'),'L’algorithme RSA-PSS SHA-256 manque.');
check(crypto.includes('metadata.KeyUsage !== "SIGN_VERIFY"'),'La destination SIGN_VERIFY n’est pas contrôlée.');
check(crypto.includes('FISCAL_KMS_AWS_ACCESS_KEY_ID')&&crypto.includes('FISCAL_KMS_AWS_SECRET_ACCESS_KEY'),'Les secrets IAM dédiés manquent.');
check(!/BEGIN (RSA |EC )?PRIVATE KEY/.test(crypto),'Une clé privée est présente dans le connecteur.');
check(exporter.includes('verify_fiscal_archive_record'),'L’intégrité SQL n’est pas contrôlée avant signature.');
check(exporter.includes('fiscalSigner.signDigest(archive.archive_hash)'),'L’empreinte d’archive n’est pas signée.');
check(exporter.includes('fiscalSigner.verifyDigest(archive.archive_hash'),'La signature KMS n’est pas vérifiée.');
check(exporter.includes('register_fiscal_archive_signature'),'La signature vérifiée n’est pas inscrite.');
check(migration.includes('create table if not exists public.fiscal_archive_signatures'),'Le registre de signatures manque.');
check(migration.includes('fiscal_archive_signatures_immutable'),'Le registre de signatures n’est pas immuable.');
check(migration.includes("current_setting('request.jwt.claim.role',true)"),'L’écriture n’est pas réservée au serveur.');
check(migration.includes('create policy fiscal_archive_signatures_select'),'La RLS du registre manque.');

console.log(JSON.stringify({ok:true,provider:'aws-kms',algorithm:'RSASSA_PSS_SHA_256',private_key_in_repo:false}));
