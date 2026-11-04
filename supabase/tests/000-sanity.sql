-- pgTAP foundation test. Run with: npx supabase test db
-- Asserts migration M01's objects: schemas, the shared enums (with labels),
-- the updated_at trigger function, and the private.* authorization helpers.
begin;
select plan(13);

-- schemas
select has_schema('public',  'public schema exists');
select has_schema('private', 'private schema exists (helpers live here)');

-- shared enums + their exact label sets
select enum_has_labels('public', 'user_role',      ARRAY['owner','staff','client'],                     'user_role labels');
select enum_has_labels('public', 'category_kind',  ARRAY['service','product'],                          'category_kind labels');
select enum_has_labels('public', 'ticket_status',  ARRAY['open','paid','void'],                         'ticket_status labels');
select enum_has_labels('public', 'line_type',      ARRAY['service','product'],                          'line_type labels');
select enum_has_labels('public', 'payment_method', ARRAY['cash','card','other'],                        'payment_method labels (gift_card added in Stage 3)');
select enum_has_labels('public', 'stock_reason',   ARRAY['sale','adjustment','restock','void_restore'], 'stock_reason labels');

-- shared updated_at trigger function
select has_function('public', 'set_updated_at', '{}'::name[], 'public.set_updated_at() exists');

-- authorization helpers
select has_function('private', 'current_role',       '{}'::name[], 'private.current_role() exists');
select has_function('private', 'is_owner',           '{}'::name[], 'private.is_owner() exists');
select has_function('private', 'is_staff_or_owner',  '{}'::name[], 'private.is_staff_or_owner() exists');
select has_function('private', 'current_staff_id',   '{}'::name[], 'private.current_staff_id() exists');

select * from finish();
rollback;
