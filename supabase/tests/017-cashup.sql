-- pgTAP — M17 cashup. Proves the owner gate (42501 for non-owners) and the aggregation
-- numbers via the internal fn. Seeds a consistent graph with triggers/FKs disabled, as
-- the superuser test role (like 014-pay-ticket), then reads it back.
begin;
select plan(14);

select has_function('public', 'cashup',
  array['timestamp with time zone', 'timestamp with time zone'], 'cashup(from,to) exists');
select is(
  (select security_type from information_schema.routines
     where routine_schema = 'public' and routine_name = 'cashup'),
  'DEFINER', 'cashup is SECURITY DEFINER');

set session_replication_role = replica;  -- bypass FK/triggers to seed a consistent graph

insert into public.staff (id, name, commission_rate, active) values
  ('55550000-0000-0000-0000-000000000001', 'Lea',  40.00, true),
  ('55550000-0000-0000-0000-000000000002', 'Maya', 30.00, true);

insert into public.ticket (id, status, opened_by, created_by, subtotal, discount_total, total, closed_at)
values ('71c00000-0000-0000-0000-0000000000c1', 'paid',
        '55550000-0000-0000-0000-000000000001', '55550000-0000-0000-0000-000000000001',
        100.00, 0, 100.00, '2026-01-01 10:00:00+00');

-- Lea: one service line, base 100 @ 40% = 40 commission
insert into public.commission_entry
  (staff_id, ticket_id, ticket_line_id, line_type, base_amount, rate, amount, is_reversal, earned_at)
values ('55550000-0000-0000-0000-000000000001', '71c00000-0000-0000-0000-0000000000c1',
        'aaaa0000-0000-0000-0000-0000000000a1', 'service', 100.00, 40.00, 40.00, false,
        '2026-01-01 10:00:00+00');

insert into public.payment (ticket_id, method, amount, created_at)
values ('71c00000-0000-0000-0000-0000000000c1', 'cash', 100.00, '2026-01-01 10:00:00+00');

insert into public.tip (ticket_id, staff_id, amount, method, created_at)
values ('71c00000-0000-0000-0000-0000000000c1', '55550000-0000-0000-0000-000000000001',
        5.00, 'cash', '2026-01-01 10:00:00+00');

reset session_replication_role;

-- gate: a non-owner (staff) claim is refused
select set_config('request.jwt.claims', '{"user_role":"staff"}', true);
select throws_ok(
  $$ select public.cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') $$,
  '42501', null, 'a non-owner caller is refused (42501)');

-- gate: the owner can read it
select set_config('request.jwt.claims', '{"user_role":"owner"}', true);
select lives_ok(
  $$ select public.cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') $$,
  'the owner can read the cash-up');

-- aggregation (read via the internal fn, as the superuser test role)
select is((private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') ->> 'gross_takings')::bigint,
  10000::bigint, 'gross takings = 100.00 in cents');
select is((private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') ->> 'tip_total')::bigint,
  500::bigint, 'tip total = 5.00 in cents');
select is((private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') ->> 'ticket_count')::bigint,
  1::bigint, 'one paid ticket closed in the window');
select is((private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') ->> 'avg_ticket')::bigint,
  10000::bigint, 'average ticket = 100.00');
select is(private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') #>> '{takings_by_method,cash}',
  '10000', 'cash takings = 100.00 in cents');

-- per-staff: only Lea earned; one row, rate 40, commission 40.00
select is(jsonb_array_length(private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') -> 'by_staff'),
  1, 'one staff row (only Lea earned in the window)');
select is(private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') #>> '{by_staff,0,name}',
  'Lea', 'the staff row is Lea');
select is((private._cashup('2026-01-01 00:00+00', '2026-01-02 00:00+00') #>> '{by_staff,0,commission_cents}')::bigint,
  4000::bigint, 'Lea commission = 40.00 in cents');

-- empty window → zeros + empty by_staff
select is((private._cashup('2020-01-01 00:00+00', '2020-01-02 00:00+00') ->> 'gross_takings')::bigint,
  0::bigint, 'an empty window has zero takings');
select is(jsonb_array_length(private._cashup('2020-01-01 00:00+00', '2020-01-02 00:00+00') -> 'by_staff'),
  0, 'an empty window has no staff rows');

select * from finish();
rollback;
