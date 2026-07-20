-- Historical migrations granted authenticated access to most functions.
-- Rebuild the signed-in RPC surface from an explicit allow-list.

revoke execute on all functions in schema public from authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

grant execute on function public.current_user_company_ids() to authenticated;
grant execute on function public.is_company_member(uuid) to authenticated;
grant execute on function public.has_company_role(uuid, text[]) to authenticated;
grant execute on function public.has_company_permission(uuid, text) to authenticated;
grant execute on function public.is_company_onboarded(uuid) to authenticated;
grant execute on function public.ensure_user_company(text) to authenticated;

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
grant execute on function public.confirm_company_email_token(uuid, text) to authenticated;
grant execute on function public.confirm_company_phone_code(uuid, text) to authenticated;

grant execute on all functions in schema public to service_role;
