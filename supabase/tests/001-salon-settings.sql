-- pgTAP — M02 salon_settings singleton. Run with: npx supabase test db
begin;
select plan(7);

select has_table('public', 'salon_settings', 'salon_settings table exists');
select has_trigger('public', 'salon_settings', 'trg_salon_settings_updated', 'updated_at trigger present');

-- exactly one row, seeded with the expected defaults
select is((select count(*) from public.salon_settings), 1::bigint, 'exactly one settings row seeded');
select is((select name from public.salon_settings where id = 1), 'Rosea', 'seeded row id=1 is named Rosea');
select is((select currency from public.salon_settings where id = 1), 'USD', 'default currency is USD');

-- singleton: a second row can never be inserted (identity -> id=2 -> CHECK (id=1) fails)
select throws_ok(
  $$ insert into public.salon_settings (name) values ('Second') $$,
  '23514', null,
  'cannot insert a second settings row (singleton CHECK id=1)'
);

-- currency must be a 3-letter uppercase ISO code
select throws_ok(
  $$ update public.salon_settings set currency = 'usd' where id = 1 $$,
  '23514', null,
  'currency must match ^[A-Z]{3}$'
);

select * from finish();
rollback;
