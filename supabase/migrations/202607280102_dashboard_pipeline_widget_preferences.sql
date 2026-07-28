-- Autorise l'indicateur de pipeline pondéré déjà proposé par le cockpit.
-- La fonction reste strictement limitée aux widgets connus et à quatre indicateurs.
create or replace function public.save_dashboard_preferences(
  target_layout_version integer,target_visible_blocks jsonb,target_block_order jsonb,
  target_block_sizes jsonb,target_selected_metrics jsonb,target_period_config jsonb
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare context_row record; allowed_blocks constant text[]:=array[
  'receivables','commercial','recent_documents','customers','catalog','stock','agenda',
  'purchases','notifications','forecast'
]; allowed_metrics constant text[]:=array[
  'revenue_ht','collected','outstanding','gross_margin','quote_count','accepted_quote_count',
  'conversion_rate','pipeline_weighted','average_invoice_ht','overdue_count','new_clients',
  'purchases_ht','stock_value','gross_result'
]; invalid_key text;
begin
  select * into context_row from public._dashboard_request_context();
  if context_row.company_id is null then raise exception 'dashboard_access_denied' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(target_visible_blocks,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_block_order,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_block_sizes,'{}'::jsonb))<>'object'
    or jsonb_typeof(coalesce(target_selected_metrics,'[]'::jsonb))<>'array'
    or jsonb_typeof(coalesce(target_period_config,'{}'::jsonb))<>'object' then
    raise exception 'invalid_dashboard_preferences';
  end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_visible_blocks,'[]'::jsonb)) item(value)
    where not(value=any(allowed_blocks)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_block:%',invalid_key; end if;
  if jsonb_array_length(coalesce(target_selected_metrics,'[]'::jsonb))>4 then raise exception 'too_many_dashboard_metrics'; end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_selected_metrics,'[]'::jsonb)) item(value)
    where not(value=any(allowed_metrics)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_metric:%',invalid_key; end if;
  select value into invalid_key from jsonb_array_elements_text(coalesce(target_block_order,'[]'::jsonb)) item(value)
    where not(value=any(allowed_blocks)) limit 1;
  if invalid_key is not null then raise exception 'invalid_dashboard_block:%',invalid_key; end if;
  insert into public.dashboard_preferences(
    company_id,user_id,layout_version,visible_blocks,block_order,block_sizes,
    selected_metrics,period_config,created_by
  ) values(
    context_row.company_id,context_row.user_id,greatest(1,coalesce(target_layout_version,1)),
    coalesce(target_visible_blocks,'[]'::jsonb),coalesce(target_block_order,'[]'::jsonb),
    coalesce(target_block_sizes,'{}'::jsonb),coalesce(target_selected_metrics,'[]'::jsonb),
    coalesce(target_period_config,'{}'::jsonb),context_row.user_id
  ) on conflict(company_id,user_id) do update set
    layout_version=excluded.layout_version,visible_blocks=excluded.visible_blocks,
    block_order=excluded.block_order,block_sizes=excluded.block_sizes,
    selected_metrics=excluded.selected_metrics,period_config=excluded.period_config,updated_at=now();
  return public.get_dashboard_preferences();
end
$$;

revoke all on function public.save_dashboard_preferences(integer,jsonb,jsonb,jsonb,jsonb,jsonb) from public,anon;
grant execute on function public.save_dashboard_preferences(integer,jsonb,jsonb,jsonb,jsonb,jsonb) to authenticated;

comment on function public.save_dashboard_preferences(integer,jsonb,jsonb,jsonb,jsonb,jsonb)
  is 'Enregistre la disposition du cockpit utilisateur, y compris l indicateur de pipeline pondere.';
