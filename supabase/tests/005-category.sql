-- pgTAP — M06 category. Run with: npx supabase test db
begin;
select plan(7);

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

select * from finish();
rollback;
