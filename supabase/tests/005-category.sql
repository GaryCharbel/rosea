-- pgTAP — M06 category. Run with: npx supabase test db
begin;
select plan(11);

select has_table('public', 'category', 'category table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.category'::regclass), 'RLS is enabled on category');
select has_trigger('public', 'category', 'trg_category_updated', 'updated_at trigger present');
select has_index('public', 'category', 'idx_category_kind', 'partial active (kind, sort_order) index');

select throws_ok(
  $$ insert into public.category (kind, name) values ('service', '   ') $$,
  '23514', null, 'blank category name rejected');
select lives_ok(
  $$ insert into public.category (kind, name) values ('service', 'Hair') $$,
  'category inserts');
select throws_ok(
  $$ insert into public.category (kind, name) values ('service', 'Hair') $$,
  '23505', null, 'duplicate (kind, name) rejected');

select has_trigger('public', 'category', 'trg_category_kind_immutable', 'kind-immutable guard present');
select lives_ok(
  $$ insert into public.category (kind, name) values ('service', 'Color') $$,
  'another category inserts');
select throws_ok(
  $$ insert into public.category (kind, name) values ('service', 'color') $$,
  '23505', null, 'case-insensitive duplicate (Color vs color) rejected');
select throws_ok(
  $$ update public.category set kind = 'product' where name = 'Hair' $$,
  '23514', null, 'category kind cannot be changed once created');

select * from finish();

rollback;
