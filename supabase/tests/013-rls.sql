-- pgTAP — Phase 2.1 RLS (privilege + structure; full role-visibility behaviour is
-- proven in the local sandbox, which needs the auth.users/profiles chain).
begin;
select plan(14);

-- RLS enabled on every app table
select ok((select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
             where n.nspname='public' and c.relname in
               ('salon_settings','staff','client','profiles','category','service','product',
                'ticket','ticket_line','payment','tip','commission_entry','stock_movement')),
  'RLS enabled on every app table');

-- §6.4 security gate (CI-enforced get_advisors equivalent): EVERY public base table
-- (excluding extension-owned) must have RLS enabled AND at least one policy. A future
-- table missing either turns this red.
select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r'
       and not exists (select 1 from pg_depend d where d.objid=c.oid and d.deptype='e')
       and (not c.relrowsecurity
            or not exists (select 1 from pg_policies p where p.schemaname='public' and p.tablename=c.relname))),
  0::bigint,
  'every public app table has RLS + at least one policy');

-- rate / commission columns hidden from the till (the column REVOKE+grant pattern)
select ok(not has_column_privilege('authenticated','public.staff','commission_rate','SELECT'),
  'authenticated cannot read staff.commission_rate');
select ok(not has_column_privilege('authenticated','public.staff','product_commission_rate','SELECT'),
  'authenticated cannot read staff.product_commission_rate');
select ok(has_column_privilege('authenticated','public.staff','name','SELECT'),
  'authenticated CAN read staff.name');
select ok(not has_column_privilege('authenticated','public.ticket_line','commission_amount','SELECT'),
  'authenticated cannot read ticket_line.commission_amount');
select ok(not has_column_privilege('authenticated','public.ticket_line','commission_rate_snapshot','SELECT'),
  'authenticated cannot read ticket_line.commission_rate_snapshot');
select ok(has_column_privilege('authenticated','public.ticket_line','line_total','SELECT'),
  'authenticated CAN read ticket_line.line_total');

-- money tables are RPC-write-only for authenticated
select ok(not has_table_privilege('authenticated','public.payment','INSERT'),          'authenticated cannot insert payment');
select ok(not has_table_privilege('authenticated','public.commission_entry','INSERT'), 'authenticated cannot insert commission_entry');
select ok(not has_table_privilege('authenticated','public.stock_movement','UPDATE'),   'authenticated cannot update stock_movement');

-- key policies present
select ok((select count(*) from pg_policies where schemaname='public' and tablename='commission_entry' and policyname='commission_read')=1, 'commission_read policy exists');
select ok((select count(*) from pg_policies where schemaname='public' and tablename='staff' and policyname='staff_write')=1, 'staff_write policy exists');
select ok((select count(*) from pg_policies where schemaname='public' and tablename='ticket' and policyname like 'ticket_staff_%')>=1, 'ticket staff policies exist');

select * from finish();
rollback;
