-- pgTAP — M12/M13 payment + tip (structural; behavior in the sandbox).
begin;
select plan(8);

select has_table('public', 'payment', 'payment table exists');
select ok((select relrowsecurity from pg_class where oid='public.payment'::regclass), 'RLS is enabled on payment');
select has_table('public', 'tip', 'tip table exists');
select ok((select relrowsecurity from pg_class where oid='public.tip'::regclass), 'RLS is enabled on tip');
select has_index('public', 'payment', 'idx_payment_method_date', 'cash-up index (method, created_at)');
select has_index('public', 'tip', 'idx_tip_staff_date', 'tip per-staff index');

-- deliberately NO open-guard on payment/tip (void writes reversals on a paid ticket)
select ok((select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relname='payment' and not t.tgisinternal)=0,
  'payment has no row trigger (no open-guard — void posts reversals on a paid ticket)');
select ok((select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relname='tip' and not t.tgisinternal)=0,
  'tip has no row trigger (no open-guard)');

select * from finish();
rollback;
