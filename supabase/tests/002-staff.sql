-- pgTAP — M03 staff + staff_public. Run with: npx supabase test db
begin;
select plan(9);

select has_table('public', 'staff', 'staff table exists');
select has_view('public', 'staff_public', 'staff_public view exists');
select ok((select relrowsecurity from pg_class where oid = 'public.staff'::regclass), 'RLS is enabled on staff');
select has_trigger('public', 'staff', 'trg_staff_updated', 'updated_at trigger present');
select has_index('public', 'staff', 'idx_staff_active', 'partial index on active staff');

-- the cashier-safe view exposes ONLY id/name/title/active — never the rate columns
select columns_are('public', 'staff_public', ARRAY['id','name','title','active'],
  'staff_public exposes only id/name/title/active (no rate columns)');

-- name must be non-blank
select throws_ok(
  $$ insert into public.staff (name) values ('   ') $$,
  '23514', null, 'blank name is rejected');

-- commission_rate must be within 0..100
select throws_ok(
  $$ insert into public.staff (name, commission_rate) values ('Over', 150) $$,
  '23514', null, 'commission_rate > 100 is rejected');

-- a valid staff row with a null product_commission_rate inserts fine
select lives_ok(
  $$ insert into public.staff (name) values ('Valid Stylist') $$,
  'valid staff row inserts (null product_commission_rate allowed)');

select * from finish();
rollback;
