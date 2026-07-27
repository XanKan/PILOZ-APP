begin;

-- Supabase db lint analyse les fonctions sans executer leur corps. La table
-- temporaire utilisee par le moteur de ventilation n'existe donc pas au moment
-- de l'analyse. Remplacer cet accumulateur par un objet JSONB conserve la meme
-- logique metier, evite tout etat partage entre deux factures et rend la
-- fonction integralement analysable par plpgsql_check.
do $replace_sales_account_accumulator$
declare
  source_definition text;
  patched_definition text;
begin
  source_definition:=pg_get_functiondef(
    'public._generate_document_accounting_entry(uuid)'::regprocedure
  );
  patched_definition:=source_definition;

  patched_definition:=replace(
    patched_definition,
    '  weight_total numeric:=0;base_total numeric:=0;remaining_discount numeric:=0;component_count integer:=0;component_index integer:=0;',
    '  weight_total numeric:=0;base_total numeric:=0;remaining_discount numeric:=0;component_count integer:=0;component_index integer:=0;'||chr(10)||
    '  sales_account_totals jsonb:=''{}''::jsonb;'
  );

  patched_definition:=replace(
    patched_definition,
    '    create temporary table if not exists piloz_sales_account_totals('||chr(10)||
    '      account_code text primary key,amount numeric not null default 0'||chr(10)||
    '    ) on commit drop;'||chr(10)||
    '    truncate table piloz_sales_account_totals;',
    '    sales_account_totals:=''{}''::jsonb;'
  );

  patched_definition:=replace(
    patched_definition,
    '          insert into piloz_sales_account_totals(account_code,amount) values(resolved_account_code,allocation)'||chr(10)||
    '          on conflict(account_code) do update set amount=piloz_sales_account_totals.amount+excluded.amount;',
    '          sales_account_totals:=jsonb_set(sales_account_totals,array[resolved_account_code],'||chr(10)||
    '            to_jsonb(coalesce((sales_account_totals->>resolved_account_code)::numeric,0)+allocation),true);'
  );

  patched_definition:=replace(
    patched_definition,
    '        insert into piloz_sales_account_totals(account_code,amount) values(resolved_account_code,line_row.amount)'||chr(10)||
    '        on conflict(account_code) do update set amount=piloz_sales_account_totals.amount+excluded.amount;',
    '        sales_account_totals:=jsonb_set(sales_account_totals,array[resolved_account_code],'||chr(10)||
    '          to_jsonb(coalesce((sales_account_totals->>resolved_account_code)::numeric,0)+line_row.amount),true);'
  );

  patched_definition:=replace(
    patched_definition,
    '      select coalesce(sum(amount),0) into base_total from piloz_sales_account_totals where amount>0;',
    '      select coalesce(sum(total_row.amount_text::numeric),0) into base_total'||chr(10)||
    '      from jsonb_each_text(sales_account_totals) as total_row(account_code,amount_text)'||chr(10)||
    '      where total_row.amount_text::numeric>0;'
  );

  patched_definition:=replace(
    patched_definition,
    '        select account_code,amount,row_number() over(order by account_code) row_number,count(*) over() row_count'||chr(10)||
    '        from piloz_sales_account_totals where amount>0 order by account_code',
    '        select total_row.account_code,total_row.amount_text::numeric amount,'||chr(10)||
    '          row_number() over(order by total_row.account_code) row_number,count(*) over() row_count'||chr(10)||
    '        from jsonb_each_text(sales_account_totals) as total_row(account_code,amount_text)'||chr(10)||
    '        where total_row.amount_text::numeric>0 order by total_row.account_code'
  );

  patched_definition:=replace(
    patched_definition,
    '        update piloz_sales_account_totals set amount=round(amount-allocation,2) where account_code=account_row.account_code;',
    '        sales_account_totals:=jsonb_set(sales_account_totals,array[account_row.account_code],'||chr(10)||
    '          to_jsonb(round(account_row.amount-allocation,2)),true);'
  );

  patched_definition:=replace(
    patched_definition,
    '    for account_row in select account_code,round(amount,2) amount from piloz_sales_account_totals where abs(amount)>0.01 order by account_code loop',
    '    for account_row in'||chr(10)||
    '      select total_row.account_code,round(total_row.amount_text::numeric,2) amount'||chr(10)||
    '      from jsonb_each_text(sales_account_totals) as total_row(account_code,amount_text)'||chr(10)||
    '      where abs(total_row.amount_text::numeric)>0.01 order by total_row.account_code'||chr(10)||
    '    loop'
  );

  if patched_definition=source_definition
     or position('piloz_sales_account_totals' in patched_definition)>0
     or position('sales_account_totals jsonb' in patched_definition)=0 then
    raise exception 'sales_account_lint_patch_not_applied';
  end if;

  execute patched_definition;
end
$replace_sales_account_accumulator$;

alter table public.company_fiscal_configurations
  alter column schema_version set default '202607270091';
update public.company_fiscal_configurations
set application_version='0.9.0-compliance.46',schema_version='202607270091',updated_at=now()
where application_version is distinct from '0.9.0-compliance.46'
   or schema_version is distinct from '202607270091';

commit;
