-- pgTAP — M18 ticket-level discount in pay_ticket. Proves the pro-rata distribution
-- (largest-remainder, exact to the cent), the per-line commission on the post-discount
-- net, discount_total, and the over-discount guard. Seeds with triggers/FKs off (like
-- 014), then pays as the staff caller.
begin;
select plan(11);

set session_replication_role = replica;

insert into public.staff (id, name, commission_rate, active) values
  ('d1000000-0000-0000-0000-000000000001', 'S1', 40.00, true),
  ('d1000000-0000-0000-0000-000000000002', 'S2', 30.00, true);

insert into auth.users (id, email) values ('d1aa0000-0000-0000-0000-00000000000a', 'staff@td');
insert into public.profiles (id, role, staff_id, full_name) values
  ('d1aa0000-0000-0000-0000-00000000000a', 'staff', 'd1000000-0000-0000-0000-000000000001', 'Staff TD');

insert into public.service (id, name, price, active) values
  ('d15e0000-0000-0000-0000-000000000064', 'Cut 100', 100.00, true),
  ('d15e0000-0000-0000-0000-000000000032', 'Cut 50',   50.00, true);

insert into public.ticket (id, status, opened_by, created_by)
values ('d17c0000-0000-0000-0000-000000000001', 'open',
        'd1000000-0000-0000-0000-000000000001', 'd1aa0000-0000-0000-0000-00000000000a');

-- two service lines: A = 100 (S1), B = 50 (S2); line_total is generated
insert into public.ticket_line
  (ticket_id, line_type, service_id, name_snapshot, unit_price, qty, line_discount, performer_staff_id)
values
  ('d17c0000-0000-0000-0000-000000000001', 'service', 'd15e0000-0000-0000-0000-000000000064',
     'Cut 100', 100.00, 1, 0, 'd1000000-0000-0000-0000-000000000001'),
  ('d17c0000-0000-0000-0000-000000000001', 'service', 'd15e0000-0000-0000-0000-000000000032',
     'Cut 50',   50.00, 1, 0, 'd1000000-0000-0000-0000-000000000002');

set session_replication_role = default;

select set_config('request.jwt.claims',
  '{"sub":"d1aa0000-0000-0000-0000-00000000000a","user_role":"staff"}', true);

-- guard: a ticket discount bigger than the ticket is refused
select throws_ok(
  $$ select public.pay_ticket('d17c0000-0000-0000-0000-000000000001'::uuid,
       '[]'::jsonb, '[]'::jsonb, '00000000-0000-0000-0000-0000000000d0'::uuid, 200.00) $$,
  'P0002', null, 'a ticket discount over the ticket total is refused');

-- pay with a $10 whole-ticket discount and the matching $140 tender
select lives_ok(
  $$ select public.pay_ticket('d17c0000-0000-0000-0000-000000000001'::uuid,
       '[{"method":"cash","amount":140.00}]'::jsonb, '[]'::jsonb,
       '00000000-0000-0000-0000-0000000000d1'::uuid, 10.00) $$,
  'pays with a $10 whole-ticket discount');

select is((select total from public.ticket where id = 'd17c0000-0000-0000-0000-000000000001'),
  140.00, 'total = 150 gross - 10 discount');
select is((select discount_total from public.ticket where id = 'd17c0000-0000-0000-0000-000000000001'),
  10.00, 'discount_total includes the ticket discount');
select is((select ticket_discount from public.ticket where id = 'd17c0000-0000-0000-0000-000000000001'),
  10.00, 'ticket_discount is stored on the ticket');
select is((select subtotal from public.ticket where id = 'd17c0000-0000-0000-0000-000000000001'),
  150.00, 'subtotal stays the pre-discount sum');

-- allocations sum to EXACTLY the discount: per-line bases sum to the discounted total
select is(
  (select sum(base_amount) from public.commission_entry
     where ticket_id = 'd17c0000-0000-0000-0000-000000000001' and not is_reversal),
  140.00, 'per-line commission bases sum to the discounted total (no cent drift)');

-- S1: base 100 - 6.67 = 93.33 @ 40% -> 37.33 (largest-remainder gave S1 the extra cent)
select is(
  (select base_amount from public.commission_entry
     where ticket_id = 'd17c0000-0000-0000-0000-000000000001'
       and staff_id = 'd1000000-0000-0000-0000-000000000001' and not is_reversal),
  93.33, 'S1 net base = 100 - 6.67');
select is(
  (select amount from public.commission_entry
     where ticket_id = 'd17c0000-0000-0000-0000-000000000001'
       and staff_id = 'd1000000-0000-0000-0000-000000000001' and not is_reversal),
  37.33, 'S1 commission = 40% of 93.33');

-- S2: base 50 - 3.33 = 46.67 @ 30% -> 14.00
select is(
  (select base_amount from public.commission_entry
     where ticket_id = 'd17c0000-0000-0000-0000-000000000001'
       and staff_id = 'd1000000-0000-0000-0000-000000000002' and not is_reversal),
  46.67, 'S2 net base = 50 - 3.33');
select is(
  (select amount from public.commission_entry
     where ticket_id = 'd17c0000-0000-0000-0000-000000000001'
       and staff_id = 'd1000000-0000-0000-0000-000000000002' and not is_reversal),
  14.00, 'S2 commission = 30% of 46.67');

select * from finish();
rollback;
