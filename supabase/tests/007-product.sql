-- pgTAP — M08 product (+ category-kind guard, oversell). Run with: npx supabase test db
begin;
select plan(9);

insert into public.category (id, kind, name) values
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'product', 'Retail'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'service', 'Hair');

select has_table('public', 'product', 'product table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.product'::regclass), 'RLS is enabled on product');
select has_trigger('public', 'product', 'trg_product_updated', 'updated_at trigger present');
select has_index('public', 'product', 'idx_product_active', 'partial active index');

select lives_ok(
  $$ insert into public.product (name, price, sku) values ('Shampoo', 12, 'SKU1') $$,
  'product inserts');
select throws_ok(
  $$ insert into public.product (name, price, sku) values ('Other', 12, 'SKU1') $$,
  '23505', null, 'duplicate sku rejected');
select lives_ok(
  $$ insert into public.product (name, price, stock_quantity) values ('Oversold', 12, -5) $$,
  'negative stock_quantity allowed (oversell, no >= 0 CHECK)');

select lives_ok(
  $$ insert into public.product (category_id, name, price) values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'P1', 12) $$,
  'product in a product-kind category inserts');
select throws_ok(
  $$ insert into public.product (category_id, name, price) values ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'P2', 12) $$,
  '23514', null, 'product in a service-kind category is rejected (kind guard)');

select * from finish();
rollback;
