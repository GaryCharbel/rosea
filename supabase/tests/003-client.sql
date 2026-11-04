-- pgTAP — M04 client. Run with: npx supabase test db
begin;
select plan(10);

select has_table('public', 'client', 'client table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.client'::regclass), 'RLS is enabled on client');
select has_trigger('public', 'client', 'trg_client_updated', 'updated_at trigger present');
select has_index('public', 'client', 'idx_client_phone', 'phone lookup index');
select has_index('public', 'client', 'idx_client_email', 'email (lower) lookup index');

-- constraints
select throws_ok(
  $$ insert into public.client (name) values ('   ') $$,
  '23514', null, 'blank name is rejected');
select throws_ok(
  $$ insert into public.client (name, email) values ('Jane', 'not-an-email') $$,
  '23514', null, 'malformed email is rejected');
select throws_ok(
  $$ insert into public.client (name, loyalty_points) values ('Jane', -1) $$,
  '23514', null, 'negative loyalty_points is rejected');

-- valid rows
select lives_ok(
  $$ insert into public.client (name) values ('Jane Doe') $$,
  'valid client inserts (email null allowed)');
select lives_ok(
  $$ insert into public.client (name, email) values ('Mia', 'mia@example.com') $$,
  'valid email is accepted');

select * from finish();
rollback;
