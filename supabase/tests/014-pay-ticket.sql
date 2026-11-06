-- pgTAP — Phase 3.1 pay_ticket (behavioral, design §7.6 pay-path cases).
-- The void cases (14,15) arrive with void_ticket (Phase 3.2); concurrency (12) is a
-- two-session race proven by the advisory lock + the already-paid guard (covered in
-- the local sandbox, not expressible in a single pgTAP transaction).
--
-- Each pay runs as its own statement (lives_ok/throws_ok) so the following table-read
-- assertions get a fresh snapshot that sees the writes (a read in the SAME statement as
-- the write would not — same-command tuples are invisible to that command's scans).
-- Seeding disables triggers/FK-triggers to insert a consistent graph as the superuser
-- test role, then restores them so the real guards are active during pay_ticket. Role
-- is simulated via the JWT claim.
begin;
select plan(34);

set session_replication_role = replica;

-- staff: rates per §7.6 (+ S3 eligible-but-null-product-rate, S4 for the rounding case)
insert into public.staff (id, name, commission_rate, product_commission_rate, active) values
  ('11111111-1111-1111-1111-111111111111','S1',40.00,10.00,true),
  ('22222222-2222-2222-2222-222222222222','S2', 0.00,null, true),
  ('33333333-3333-3333-3333-333333333333','S3',40.00,null, true),
  ('44444444-4444-4444-4444-444444444444','S4',33.50,null, true);

-- caller = a staff account linked to S1; plus a client account for the denial case
insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','staff@test'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc','client@test');
insert into public.profiles (id, role, staff_id, full_name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','staff','11111111-1111-1111-1111-111111111111','Staff One');
insert into public.profiles (id, role, full_name) values
  ('cccccccc-cccc-cccc-cccc-cccccccccccc','client','Client One');

-- catalog
insert into public.service (id, name, price, active) values
  ('5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,true),
  ('5e415e41-0000-0000-0000-000000000017','Trim',16.70,true);
insert into public.product (id, name, price, track_stock, stock_quantity, commission_eligible, active) values
  ('9a0d0000-0000-0000-0000-000000000001','P_elig',  50.00,true,10,true, true),
  ('9a0d0000-0000-0000-0000-000000000002','P_noelig',40.00,true,10,false,true);

-- one ticket per case (opened by S1, created by the caller)
insert into public.ticket (id, status, opened_by, created_by)
select id, 'open', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
from (values
  ('71c00000-0000-0000-0000-000000000001'::uuid),('71c00000-0000-0000-0000-000000000002'::uuid),
  ('71c00000-0000-0000-0000-000000000003'::uuid),('71c00000-0000-0000-0000-000000000004'::uuid),
  ('71c00000-0000-0000-0000-000000000005'::uuid),('71c00000-0000-0000-0000-000000000006'::uuid),
  ('71c00000-0000-0000-0000-000000000007'::uuid),('71c00000-0000-0000-0000-000000000008'::uuid),
  ('71c00000-0000-0000-0000-000000000009'::uuid),('71c00000-0000-0000-0000-000000000010'::uuid),
  ('71c00000-0000-0000-0000-000000000016'::uuid),('71c00000-0000-0000-0000-000000000017'::uuid),
  ('71c00000-0000-0000-0000-000000000013'::uuid)
) v(id);

-- service lines
insert into public.ticket_line (ticket_id, line_type, service_id, name_snapshot, unit_price, qty, line_discount, performer_staff_id) values
  ('71c00000-0000-0000-0000-000000000001','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000004','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000005','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,100,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000006','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000007','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000008','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000009','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '22222222-2222-2222-2222-222222222222'),
  ('71c00000-0000-0000-0000-000000000013','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,0,  '11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000017','service','5e415e41-0000-0000-0000-000000000017','Trim',        16.70,1,0,  '44444444-4444-4444-4444-444444444444');
-- product lines
insert into public.ticket_line (ticket_id, line_type, service_id, name_snapshot, unit_price, qty, performer_staff_id) values
  ('71c00000-0000-0000-0000-000000000002','service','5e415e41-0000-0000-0000-000000000001','Women''s Cut',100.00,1,'11111111-1111-1111-1111-111111111111');
insert into public.ticket_line (ticket_id, line_type, product_id, name_snapshot, unit_price, qty, performer_staff_id) values
  ('71c00000-0000-0000-0000-000000000002','product','9a0d0000-0000-0000-0000-000000000001','P_elig',  50.00, 1,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000003','product','9a0d0000-0000-0000-0000-000000000002','P_noelig',40.00, 1,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000010','product','9a0d0000-0000-0000-0000-000000000001','P_elig',  50.00,15,'11111111-1111-1111-1111-111111111111'),
  ('71c00000-0000-0000-0000-000000000016','product','9a0d0000-0000-0000-0000-000000000001','P_elig',  50.00, 1,'33333333-3333-3333-3333-333333333333');

set session_replication_role = default;

-- sign in as the staff caller
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","user_role":"staff"}', true);

-- CASE 1: service 100 @ 40%
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000001',
  '[{"method":"card","amount":100.00}]','[]','d1000000-0000-0000-0000-000000000001') $$, 'case1: service pays');
select is((select status::text from public.ticket where id='71c00000-0000-0000-0000-000000000001'),
  'paid', 'case1: ticket is paid');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000001'),
  40.00, 'case1: commission = 100 * 40% = 40.00');

-- CASE 2: service 40 + product 5 = 45.00 ; one sale movement of -1
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000002',
  '[{"method":"cash","amount":150.00}]','[]','d1000000-0000-0000-0000-000000000002') $$, 'case2: service+product pays');
select is((select coalesce(sum(amount),0) from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000002'),
  45.00, 'case2: commission 40 (service) + 5 (10% of 50) = 45.00');
select is((select qty_delta from public.stock_movement where ticket_id='71c00000-0000-0000-0000-000000000002'),
  -1, 'case2: P_elig sale movement -1');

-- CASE 3: not-eligible product -> entry amount 0 ; stock still ledgered -1
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000003',
  '[{"method":"card","amount":40.00}]','[]','d1000000-0000-0000-0000-000000000003') $$, 'case3: non-eligible product pays');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000003'),
  0.00, 'case3: non-eligible product earns 0');
select is((select qty_delta from public.stock_movement where ticket_id='71c00000-0000-0000-0000-000000000003'),
  -1, 'case3: P_noelig still decrements stock (-1)');

-- CASE 4: split 40 + 60 = 100
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000004',
  '[{"method":"cash","amount":40.00},{"method":"card","amount":60.00}]','[]','d1000000-0000-0000-0000-000000000004') $$,
  'case4: split pays');
select is((select count(*) from public.payment where ticket_id='71c00000-0000-0000-0000-000000000004'),
  2::bigint, 'case4: split records two payment rows');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000004'),
  40.00, 'case4: commission unaffected by split = 40.00');

-- CASE 5: fully discounted to 0 -> payable with empty tender
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000005',
  '[]','[]','d1000000-0000-0000-0000-000000000005') $$, 'case5: zero-total ticket pays with no tender');
select is((select total from public.ticket where id='71c00000-0000-0000-0000-000000000005'),
  0.00, 'case5: total is 0.00');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000005'),
  0.00, 'case5: commission on a 0 line = 0.00');

-- CASE 6: inline tip 10 to S1
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000006',
  '[{"method":"card","amount":100.00,"tip_amount":10.00,"tip_staff_id":"11111111-1111-1111-1111-111111111111"}]',
  '[]','d1000000-0000-0000-0000-000000000006') $$, 'case6: pays with an inline tip');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000006'),
  40.00, 'case6: commission 40.00 alongside a tip');
select is((select amount from public.tip where ticket_id='71c00000-0000-0000-0000-000000000006'),
  10.00, 'case6: tip row of 10.00 for S1');

-- CASE 7: underpay (90 of 100) -> P0002
select throws_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000007',
  '[{"method":"cash","amount":90.00}]','[]','d1000000-0000-0000-0000-000000000007') $$,
  'P0002', null, 'case7: underpay raises P0002');

-- CASE 8: overpay (120 of 100) -> P0002 (applied != total; change is display-only)
select throws_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000008',
  '[{"method":"cash","amount":120.00}]','[]','d1000000-0000-0000-0000-000000000008') $$,
  'P0002', null, 'case8: overpay raises P0002');

-- CASE 18: a negative applied amount is rejected even when the split sums to the total
-- (reuses T7, still open after case7 rolled back). Guards against bogus negative money rows.
select throws_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000007',
  '[{"method":"cash","amount":150.00},{"method":"card","amount":-50.00}]','[]','d1000000-0000-0000-0000-000000000018') $$,
  'P0002', null, 'case18: negative applied amount rejected despite the split summing to total');

-- CASE 9: performer S2 (rate 0) -> entry amount 0
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000009',
  '[{"method":"cash","amount":100.00}]','[]','d1000000-0000-0000-0000-000000000009') $$, 'case9: zero-rate performer pays');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000009'),
  0.00, 'case9: zero-rate performer earns 0');

-- CASE 10: oversell qty 15 (stock 10) -> paid, sale movement -15
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000010',
  '[{"method":"cash","amount":750.00}]','[]','d1000000-0000-0000-0000-000000000010') $$, 'case10: oversell pays');
select is((select status::text from public.ticket where id='71c00000-0000-0000-0000-000000000010'),
  'paid', 'case10: oversell is allowed, status paid');
select is((select qty_delta from public.stock_movement where ticket_id='71c00000-0000-0000-0000-000000000010'),
  -15, 'case10: sale movement -15 (stock goes negative)');

-- CASE 16: eligible product but performer S3 has null product rate -> amount 0 (no fallback)
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000016',
  '[{"method":"cash","amount":50.00}]','[]','d1000000-0000-0000-0000-000000000016') $$, 'case16: eligible product, null rate, pays');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000016'),
  0.00, 'case16: null product rate never falls back to the service rate');

-- CASE 17: rounding 16.70 @ 33.50% = 5.5945 -> 5.59 (half-away-from-zero)
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000017',
  '[{"method":"cash","amount":16.70}]','[]','d1000000-0000-0000-0000-000000000017') $$, 'case17: rounding case pays');
select is((select amount from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000017'),
  5.59, 'case17: 16.70 * 33.50% rounds to 5.59');

-- CASE 11: idempotent replay of case 1 (same client_tx) -> still exactly 1 entry, 1 payment
select lives_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000001',
  '[{"method":"card","amount":100.00}]','[]','d1000000-0000-0000-0000-000000000001') $$,
  'case11: replay with the same client_tx is a no-op');
select is((select count(*) from public.commission_entry where ticket_id='71c00000-0000-0000-0000-000000000001'),
  1::bigint, 'case11: replay did not double the commission entry');
select is((select count(*) from public.payment where ticket_id='71c00000-0000-0000-0000-000000000001'),
  1::bigint, 'case11: replay did not double the payment');

-- CASE 13: a client-role caller is denied
select set_config('request.jwt.claims',
  '{"sub":"cccccccc-cccc-cccc-cccc-cccccccccccc","user_role":"client"}', true);
select throws_ok($$ select public.pay_ticket('71c00000-0000-0000-0000-000000000013',
  '[{"method":"cash","amount":100.00}]','[]','d1000000-0000-0000-0000-000000000013') $$,
  '42501', null, 'case13: client caller raises insufficient_privilege');

select * from finish();
rollback;
