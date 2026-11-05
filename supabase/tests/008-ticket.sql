-- pgTAP — M09 ticket (structural; full behavioral runs in the local sandbox).
-- Inserting a ticket needs created_by -> profiles -> auth.users (FK chain not safe to
-- fabricate in CI), so behavior is exercised in the sandbox; here we assert structure.
begin;
select plan(8);

select has_table('public', 'ticket', 'ticket table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.ticket'::regclass), 'RLS is enabled on ticket');
select has_trigger('public', 'ticket', 'trg_ticket_updated', 'updated_at trigger present');
select has_index('public', 'ticket', 'idx_ticket_status_opened', 'status/opened_at index');
select has_index('public', 'ticket', 'idx_ticket_client', 'client index');
select has_index('public', 'ticket', 'idx_ticket_closed_at', 'partial paid closed_at index');
select ok((select count(*) from pg_constraint where conname = 'ticket_closed_at_chk' and conrelid='public.ticket'::regclass)=1,
  'ticket_closed_at_chk constraint exists');
select ok((select count(*) from pg_constraint where conname = 'ticket_appointment_stage1' and conrelid='public.ticket'::regclass)=1,
  'ticket_appointment_stage1 (appointment pinned null) constraint exists');

select * from finish();
rollback;
