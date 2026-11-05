-- pgTAP — M11 ticket_line + immutability guard (structural; behavior in the sandbox).
begin;
select plan(10);

select has_table('public', 'ticket_line', 'ticket_line table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.ticket_line'::regclass), 'RLS is enabled on ticket_line');
select has_index('public', 'ticket_line', 'idx_ticket_line_ticket', 'ticket index');
select has_index('public', 'ticket_line', 'idx_ticket_line_performer', 'performer index');
select has_trigger('public', 'ticket_line', 'trg_line_open', 'immutability guard trigger present');
select has_function('public', 'guard_child_only_when_open', 'guard function exists');
select ok(
  (select attgenerated from pg_attribute where attrelid='public.ticket_line'::regclass and attname='line_total') = 's',
  'line_total is a STORED generated column');
select ok((select count(*) from pg_constraint where conname='ticket_line_kind_chk' and conrelid='public.ticket_line'::regclass)=1,
  'ticket_line_kind_chk constraint exists');
select ok((select count(*) from pg_constraint where conname='ticket_line_product_whole_qty' and conrelid='public.ticket_line'::regclass)=1,
  'ticket_line_product_whole_qty constraint exists');
select ok((select count(*) from pg_constraint where conname='ticket_line_discount_chk' and conrelid='public.ticket_line'::regclass)=1,
  'ticket_line_discount_chk constraint exists');

select * from finish();
rollback;
