-- pgTAP — M14 commission_entry (structural; behavior in the sandbox).
begin;
select plan(7);

select has_table('public', 'commission_entry', 'commission_entry table exists');
select ok((select relrowsecurity from pg_class where oid='public.commission_entry'::regclass), 'RLS is enabled on commission_entry');
select has_index('public', 'commission_entry', 'uq_commission_line_earning', 'unique earning-per-line index');
select has_index('public', 'commission_entry', 'uq_commission_line_reversal', 'unique reversal-per-line index');
select has_index('public', 'commission_entry', 'idx_commission_staff_earned', 'staff/earned_at index (no N+1 on payroll reads)');
select ok((select count(*) from pg_constraint where conrelid='public.commission_entry'::regclass and contype='c')>=1,
  'commission_entry has the rate CHECK');
select ok((select count(*) from pg_constraint where conname='commission_amount_chk' and conrelid='public.commission_entry'::regclass)=1,
  'commission_amount_chk enforces amount = round(base*rate/100,2)');

select * from finish();
rollback;
