-- Restore authenticated access to the optional sales terms reference added in
-- migration 202607260071. Documents use column-level grants, therefore adding
-- the column without extending the grant made the complete PostgREST select
-- fail and the UI appeared empty even though no document had been deleted.

grant select(selected_sales_terms_id)
on public.documents
to authenticated;

