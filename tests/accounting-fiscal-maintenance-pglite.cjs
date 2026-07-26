const {loadPGlite,bootstrap,setIdentity}=require('./helpers/pglite-bootstrap.cjs');

const actor='a1000000-0000-4000-8000-000000000001';
const company='c1000000-0000-4000-8000-000000000001';

async function main(){
 const {PGlite,pgcrypto}=loadPGlite(),db=new PGlite({extensions:{pgcrypto}});
 await bootstrap(db);
 await db.exec("create or replace function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),current_user::text) $$");
 await db.query('insert into auth.users(id,email) values($1,$2)',[actor,'compta@piloz.fr']);
 await db.query('insert into public.companies(id,owner_user_id,name) values($1,$2,$3)',[company,actor,'Entreprise comptable']);
 await db.query('insert into public.company_members(company_id,user_id,role) values($1,$2,$3)',[company,actor,'owner']);
 await setIdentity(db,actor);
 const current=(await db.query("select * from public.accounting_fiscal_years where company_id=$1 and status='open' limit 1",[company])).rows[0];
 if(!current)throw new Error('Exercice initial absent');

 const nextId=(await db.query('select public.create_next_accounting_fiscal_year($1) id',[current.id])).rows[0].id;
 const next=(await db.query('select * from public.accounting_fiscal_years where id=$1',[nextId])).rows[0];
 if(next.previous_year_id!==current.id||next.status!=='upcoming')throw new Error('Chaînage N+1 invalide');
 const duration=Number((await db.query('select ($1::date-$2::date) value',[next.ends_on,next.starts_on])).rows[0].value);
 const currentDuration=Number((await db.query('select ($1::date-$2::date) value',[current.ends_on,current.starts_on])).rows[0].value);
 if(duration!==currentDuration)throw new Error('Durée N+1 différente');
 const idempotent=(await db.query('select public.create_next_accounting_fiscal_year($1) id',[current.id])).rows[0].id;
 if(idempotent!==nextId)throw new Error('Création N+1 non idempotente');

 const closed=(await db.query('select public.close_accounting_fiscal_year($1) value',[current.id])).rows[0].value;
 if(!closed.closed)throw new Error('Clôture refusée sans erreur comptable');
 const status=(await db.query('select status from public.accounting_fiscal_years where id=$1',[current.id])).rows[0].status;
 if(status!=='closed')throw new Error('Exercice non clôturé');

 await db.exec("reset role; set request.jwt.claim.role='service_role'; set role service_role");
 const maintenance=(await db.query("select public.run_accounting_fiscal_maintenance('2026-10-15T02:17:00Z'::timestamptz) value")).rows[0].value;
 if(!Object.prototype.hasOwnProperty.call(maintenance,'next_years_created'))throw new Error('Rapport de maintenance incomplet');
 await db.close();
 console.log(JSON.stringify({ok:true,currentYear:current.name,nextYear:next.name,nextId,status,maintenance}));
}

main().catch(error=>{console.error(error);process.exit(1);});
