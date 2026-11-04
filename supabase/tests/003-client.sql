-- pgTAP — M04 client. Run with: npx supabase test db
begin;
select plan(14);

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

-- phone is a unique identifier (when provided)
select index_is_unique('public', 'client', 'idx_client_phone', 'phone index is unique');
select lives_ok(
  $$ insert into public.client (name, phone) values ('Ann', '03-111222') $$,
  'first client with a phone inserts');
select throws_ok(
  $$ insert into public.client (name, phone) values ('Bob', '03-111222') $$,
  '23505', null, 'duplicate phone is rejected (unique)');
-- but phone stays optional: many walk-ins without a phone are allowed (NULLs distinct)
select lives_ok(
  $$ insert into public.client (name) values ('Walk-in A'), ('Walk-in B') $$,
  'multiple clients with a null phone are allowed');

select * from finish();
rollback;
