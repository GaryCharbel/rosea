-- Seed: a demo salon so the POS is testable immediately (Phase 5.1).
-- Idempotent (fixed ids + ON CONFLICT DO NOTHING) so `supabase db reset` — or a paste
-- into a hosted SQL editor — is safe to re-run. Public tables only; the seed runs as a
-- superuser so RLS/owner-write policies don't block it. Auth users live in 00_auth.sql.

-- ── salon identity (the singleton seeded in M02) ──────────────────────────────
-- Keep name = 'Rosea' (the M02 default a migration test pins); the full salon name
-- lives in receipt_header, which is what the printed receipt shows.
update public.salon_settings set
  currency       = 'USD',
  address        = '123 Rosea Lane',
  receipt_header = 'Rosea Beauty Salon',
  receipt_footer = 'Thank you — we can''t wait to see you again!'
where id = 1;

-- ── categories ────────────────────────────────────────────────────────────────
insert into public.category (id, kind, name, sort_order) values
  ('ca000000-0000-0000-0000-0000000000c1', 'service', 'Hair',   1),
  ('ca000000-0000-0000-0000-0000000000c2', 'service', 'Color',  2),
  ('ca000000-0000-0000-0000-0000000000c3', 'service', 'Nails',  3),
  ('ca000000-0000-0000-0000-0000000000c4', 'product', 'Retail', 4)
on conflict (id) do nothing;

-- ── services ──────────────────────────────────────────────────────────────────
insert into public.service (id, category_id, name, price, duration_minutes, sort_order) values
  ('5e000000-0000-0000-0000-000000000001', 'ca000000-0000-0000-0000-0000000000c1', 'Women''s Cut',   45.00,  45, 1),
  ('5e000000-0000-0000-0000-000000000002', 'ca000000-0000-0000-0000-0000000000c1', 'Men''s Cut',     30.00,  30, 2),
  ('5e000000-0000-0000-0000-000000000003', 'ca000000-0000-0000-0000-0000000000c1', 'Blow Dry',       35.00,  30, 3),
  ('5e000000-0000-0000-0000-000000000004', 'ca000000-0000-0000-0000-0000000000c2', 'Full Color',     90.00, 120, 1),
  ('5e000000-0000-0000-0000-000000000005', 'ca000000-0000-0000-0000-0000000000c2', 'Highlights',    120.00, 150, 2),
  ('5e000000-0000-0000-0000-000000000006', 'ca000000-0000-0000-0000-0000000000c2', 'Root Touch-up',  70.00,  90, 3),
  ('5e000000-0000-0000-0000-000000000007', 'ca000000-0000-0000-0000-0000000000c3', 'Manicure',       25.00,  30, 1),
  ('5e000000-0000-0000-0000-000000000008', 'ca000000-0000-0000-0000-0000000000c3', 'Pedicure',       40.00,  45, 2)
on conflict (id) do nothing;

-- ── products (some commission-eligible + stock-tracked; one of each not) ───────
insert into public.product (id, category_id, name, price, sku, track_stock, stock_quantity, commission_eligible, sort_order) values
  ('9a000000-0000-0000-0000-000000000001', 'ca000000-0000-0000-0000-0000000000c4', 'Shampoo 250ml',     18.00, 'SH-250', true,  40, true,  1),
  ('9a000000-0000-0000-0000-000000000002', 'ca000000-0000-0000-0000-0000000000c4', 'Conditioner 250ml', 20.00, 'CO-250', true,  35, true,  2),
  ('9a000000-0000-0000-0000-000000000003', 'ca000000-0000-0000-0000-0000000000c4', 'Argan Hair Oil',    28.00, 'OIL-01', true,  20, true,  3),
  ('9a000000-0000-0000-0000-000000000004', 'ca000000-0000-0000-0000-0000000000c4', 'Styling Gel',       15.00, 'GEL-01', true,  25, false, 4), -- not commission-eligible
  ('9a000000-0000-0000-0000-000000000005', 'ca000000-0000-0000-0000-0000000000c4', 'Gift Card',          2.00, 'GC-01',  false,  0, false, 5)  -- untracked stock
on conflict (id) do nothing;

-- ── staff with varied commission rates (Maya earns 0 on products: null rate) ──
insert into public.staff (id, name, title, commission_rate, product_commission_rate) values
  ('57000000-0000-0000-0000-0000000000a1', 'Lea',  'Senior Stylist',  40.00, 10.00),
  ('57000000-0000-0000-0000-0000000000a2', 'Maya', 'Stylist',         35.00, null),
  ('57000000-0000-0000-0000-0000000000a3', 'Sam',  'Nail Technician', 30.00,  8.00)
on conflict (id) do nothing;

-- ── a sample client ───────────────────────────────────────────────────────────
insert into public.client (id, name, phone, email) values
  ('c1000000-0000-0000-0000-000000000001', 'Nour Haddad', '+961 70 123 456', 'nour@example.com')
on conflict (id) do nothing;
