-- pgTAP — Phase 3.2 void_ticket (design §7.6 cases 14-15 + state/authz guards).
-- Pay a multi-line ticket as staff, then void it as owner and assert the ledger nets
-- to zero, stock is restored, and the void is idempotent + owner-only.
-- Same seeding approach as 014 (triggers off to seed, JWT claim to simulate the role).
begin;
select plan(18);

set session_replication_role = replica;

insert into public.staff (id, name, commission_rate, product_commission_rate, active) values
  ('11111111-1111-1111-1111-111111111111','S1',40.00,10.00,true);

-- a staff caller (takes payment) and an owner caller (voids); owner has no staff link
insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','staff@test'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','owner@test');
insert into public.profiles (id, role, staff_id, full_name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','staff','11111111-1111-1111-1111-111111111111','Staff One');
insert into public.profiles (id, role, full_name) values
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','owner','Owner One');

insert into public.service (id, name, price, active) values
  ('5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,true);
insert into public.product (id, name, price, track_stock, stock_quantity, commission_eligible, active) values
  ('9a0d0000-0000-0000-0000-000000000001','P_elig',50.00,true,10,true,true);

-- T(a0): service + product -> paid, then voided ; T3(a3): an open ticket ;
-- T4(a4): a second paid ticket for the cross-ticket void-id reuse check
insert into public.ticket (id, status, opened_by, created_by) values
  ('71c00000-0000-0000-0000-0000000000a0','open','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('71c00000-0000-0000-0000-0000000000a3','open','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('71c00000-0000-0000-0000-0000000000a4','open','11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
insert into public.ticket_line (ticket_id, line_type, service_id, name_snapshot, unit_price, qty, performer_staff_id) values
  ('71c00000-0000-0000-0000-0000000000a0','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-0000000000a3','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-0000000000a4','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,'11111111-1111-1111-1111-111111111111');
insert into public.ticket_line (ticket_id, line_type, product_id, name_snapshot, unit_price, qty, performer_staff_id) values
  ('71c00000-0000-0000-0000-0000000000a0','product','9a0d0000-0000-0000-0000-000000000001','P_elig',50.00,1,'11111111-1111-1111-1111-111111111111');

set session_replication_role = default;

-- pay the ticket as staff
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user_role":"staff"}', true);
-- pays 150 to the ticket plus a 10 inline tip to S1, so the void exercises the
-- payment AND the tip reversal branches.
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-0000000000a0',
  '[{"method":"cash","amount":150.00,"tip_amount":10.00,"tip_staff_id":"11111111-1111-1111-1111-111111111111"}]',
  '[]','d1000000-0000-0000-0000-0000000000a1') $$, 'setup: ticket pays with a tip');

-- CASE 14: void as owner
select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","user_role":"owner"}', true);
select lives_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a0','customer refund',
  'd1000000-0000-0000-0000-0000000000a2') $$, 'case14: owner voids a paid ticket');
select is((select status::text from public.ticket where id='71c00000-0000-0000-0000-0000000000a0'),
  'void', 'case14: ticket is void');
select is((select coalesce(sum(amount),0) from public.commission_entry where ticket_id='71c00000-0000-0000-0000-0000000000a0'),
  0.00, 'case14: commission nets to 0 after reversal');
select is((select count(*) from public.commission_entry where ticket_id='71c00000-0000-0000-0000-0000000000a0' and is_reversal),
  2::bigint, 'case14: two reversal entries (one per earning line)');
select is((select stock_quantity from public.product where id='9a0d0000-0000-0000-0000-000000000001'),
  10, 'case14: P_elig stock restored to 10');
select is((select qty_delta from public.stock_movement where ticket_id='71c00000-0000-0000-0000-0000000000a0' and reason='void_restore'),
  1, 'case14: a void_restore movement of +1');
select is((select coalesce(sum(amount),0) from public.payment where ticket_id='71c00000-0000-0000-0000-0000000000a0'),
  0.00, 'case14: payments net to 0 after reversal');
select is((select coalesce(sum(amount),0) from public.tip where ticket_id='71c00000-0000-0000-0000-0000000000a0'),
  0.00, 'case14: tips net to 0 after reversal (tip reversal branch)');
-- the void payload reports NET money: no payments/tips remain (not the original positives)
select is(jsonb_array_length((public._pay_ticket_result('71c00000-0000-0000-0000-0000000000a0'))->'payments'),
  0, 'case14: void payload shows no net payments');
select is(((public._pay_ticket_result('71c00000-0000-0000-0000-0000000000a0'))->>'tip_total')::numeric,
  0.00, 'case14: void payload tip_total is 0');

-- CASE 15a: idempotent replay of the void (same client_tx) -> no-op, still 2 reversals
select lives_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a0','customer refund',
  'd1000000-0000-0000-0000-0000000000a2') $$, 'case15a: void replay is a no-op');
select is((select count(*) from public.commission_entry where ticket_id='71c00000-0000-0000-0000-0000000000a0' and is_reversal),
  2::bigint, 'case15a: replay did not add reversal rows');

-- CASE 15b: a different client_tx against an already-voided ticket -> P0001
select throws_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a0','again',
  'd1000000-0000-0000-0000-0000000000a9') $$, 'P0001', null, 'case15b: re-void with a new tx raises P0001');

-- CASE 15c: a non-owner (staff) caller is denied (authz runs before state checks)
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user_role":"staff"}', true);
select throws_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a0','nope',
  'd1000000-0000-0000-0000-0000000000aa') $$, '42501', null, 'case15c: staff caller cannot void');

-- GUARD: an open (unpaid) ticket cannot be voided
select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","user_role":"owner"}', true);
select throws_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a3','open',
  'd1000000-0000-0000-0000-0000000000ab') $$, 'P0001', null, 'guard: cannot void an open ticket');

-- CROSS-TICKET VOID-ID REUSE: pay a4, then try to void it reusing a0's void_tx -> P0001
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user_role":"staff"}', true);
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-0000000000a4',
  '[{"method":"cash","amount":100.00}]','[]','d1000000-0000-0000-0000-0000000000a5') $$, 'setup: second ticket pays');
select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","user_role":"owner"}', true);
select throws_ok($$ select public.void_ticket('71c00000-0000-0000-0000-0000000000a4','reuse',
  'd1000000-0000-0000-0000-0000000000a2') $$, 'P0001', null, 'void: reusing another ticket''s void id raises P0001');

select * from finish();
rollback;
