begin;

-- Le module Stock n’est pas encore proposé dans Piloz. Ses autorisations sont
-- conservées pour la roadmap, mais retirées de tous les éditeurs de rôles.
update public.permission_definitions
set editor_visible=false,updated_at=now()
where module_key='stock'
   or category_key='stock'
   or canonical_key like 'stock.%'
   or permission_key in('adjust_stock');

commit;
