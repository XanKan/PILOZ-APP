-- Harden the exposed API without changing business data.
-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default; remove that
-- inheritance and explicitly expose only the RPCs required by signed-in users.

revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public;

-- Helpers used by RLS policies and onboarding.
grant execute on function public.current_user_company_ids() to authenticated;
grant execute on function public.is_company_member(uuid) to authenticated;
grant execute on function public.has_company_role(uuid, text[]) to authenticated;
grant execute on function public.has_company_permission(uuid, text) to authenticated;
grant execute on function public.is_company_onboarded(uuid) to authenticated;
grant execute on function public.ensure_user_company(text) to authenticated;

-- Business operations intentionally available to signed-in users. Every
-- SECURITY DEFINER implementation validates membership/permissions internally.
grant execute on function public.get_company_financial_fields(uuid) to authenticated;
grant execute on function public.next_document_number(uuid, text, integer) to authenticated;
grant execute on function public.validate_invoice(uuid) to authenticated;
grant execute on function public.confirm_sales_order(uuid, uuid) to authenticated;
grant execute on function public.cancel_sales_order(uuid) to authenticated;
grant execute on function public.validate_delivery(uuid) to authenticated;
grant execute on function public.reverse_stock_movement(uuid, text) to authenticated;
grant execute on function public.confirm_purchase_order(uuid) to authenticated;
grant execute on function public.validate_goods_receipt(uuid) to authenticated;
grant execute on function public.validate_inventory_count(uuid) to authenticated;
grant execute on function public.validate_supplier_return(uuid) to authenticated;
grant execute on function public.convert_quote_to_invoice(uuid, text) to authenticated;
grant execute on function public.record_document_payment(uuid, numeric, text, text, timestamptz) to authenticated;
grant execute on function public.post_stock_movement(uuid, uuid, text, numeric, text, uuid, uuid, uuid, uuid, text, text, numeric) to authenticated;

-- Confirmation functions are called with the user's JWT by trusted Edge
-- Functions. Template version persistence uses the service role only.
grant execute on function public.confirm_company_email_token(uuid, text) to authenticated;
grant execute on function public.confirm_company_phone_code(uuid, text) to authenticated;

grant execute on all functions in schema public to service_role;

alter function public.set_current_timestamp_updated_at() set search_path = public, pg_temp;
