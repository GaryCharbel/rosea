-- pgTAP — M07 service (+ category-kind guard). Run with: npx supabase test db
begin;
select plan(9);

insert into public.category (id, kind, name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'service', 'Hair'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'product', 'Retail');

select has_table('public', 'service', 'service table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.service'::regclass), 'RLS is enabled on service');
select has_trigger('public', 'service', 'trg_service_updated', 'updated_at trigger present');
select has_index('public', 'service', 'idx_service_active', 'partial active index');

select throws_ok(
  $$ insert into public.service (name, price) values ('X', -1) $$,
  '23514', null, 'negative price rejected');
select throws_ok(
  $$ insert into public.service (name, price, duration_minutes) values ('X', 10, 0) $$,
  '23514', null, 'duration_minutes must be > 0');

select lives_ok(
  $$ insert into public.service (category_id, name, price) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Cut', 30) $$,
  'service in a service-kind category inserts');
select throws_ok(
  $$ insert into public.service (category_id, name, price) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Cut2', 30) $$,
  '23514', null, 'service in a product-kind category is rejected (kind guard)');
select lives_ok(
  $$ insert into public.service (name, price) values ('No Category', 30) $$,
  'service with a null category inserts (guard skipped)');

select * from finish();
rollback;
