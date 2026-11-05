-- pgTAP — M15 stock_movement. Run with: npx supabase test db
-- stock_movement.ticket_id is nullable, so this one can run behaviorally in CI
-- (only needs a product, which has no auth FK chain).
begin;
select plan(5);

insert into public.product (name, price) values ('Widget', 5);

select has_table('public', 'stock_movement', 'stock_movement table exists');
select ok((select relrowsecurity from pg_class where oid='public.stock_movement'::regclass), 'RLS is enabled on stock_movement');
select has_index('public', 'stock_movement', 'idx_stock_movement_product', 'product/created_at index');
select throws_ok(
  $$ insert into public.stock_movement (product_id, reason, qty_delta)
     select id, 'sale', 0 from public.product where name='Widget' $$,
  '23514', null, 'qty_delta <> 0 enforced');
select lives_ok(
  $$ insert into public.stock_movement (product_id, reason, qty_delta)
     select id, 'sale', -3 from public.product where name='Widget' $$,
  'negative qty_delta (a sale) is allowed');

select * from finish();
rollback;
