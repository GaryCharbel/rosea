-- M16 — RLS policies (Phase 2.1), per the §6.2 matrix.
-- RLS is already ENABLED on every table (at creation). This migration adds the
-- policies, the column-level REVOKEs, the own-involved ticket helper, and the
-- money-table RPC-write-only lockdown. All policies are `to authenticated` and wrap
-- helper calls in `(select ...)` so they evaluate once per query (initplan caching).
-- anon gets NO policy anywhere in Stage 1 (catalog anon-read is a Stage-2 hook) ->
-- anon is default-denied on every table. Helpers are SECURITY DEFINER (bypass RLS),
-- so policies that read profiles/ticket via them do not recurse.

-- ── keep rate / per-line commission columns off the cashier till ──
-- IMPORTANT: a column-level REVOKE does NOT override a table-level SELECT grant
-- (Supabase grants `authenticated` table-level SELECT by default), so revoking just
-- the sensitive columns is ineffective. Instead drop the table-level SELECT and
-- re-grant SELECT on the non-sensitive columns only.
revoke select on public.staff from authenticated;
grant  select (id, name, title, active, user_id, created_at, updated_at)
  on public.staff to authenticated;                           -- NO commission_rate / product_commission_rate
revoke select on public.ticket_line from authenticated;
grant  select (id, ticket_id, line_type, service_id, product_id, name_snapshot,
               unit_price, qty, line_discount, line_total, performer_staff_id, created_at)
  on public.ticket_line to authenticated;                     -- NO commission_rate_snapshot / commission_amount
grant  select on public.staff_public to authenticated;

-- ── own-involved ticket helper (created the ticket, or performed a line on it) ──
create or replace function private.my_ticket_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select t.id from public.ticket t where t.created_by = (select auth.uid())
  union
  select tl.ticket_id from public.ticket_line tl where tl.performer_staff_id = private.current_staff_id();
$$;
grant execute on function private.my_ticket_ids() to authenticated;

-- ── caller's own client id(s) (for client self-reads) ──
create or replace function private.my_client_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select c.id from public.client c where c.user_id = (select auth.uid());
$$;
grant execute on function private.my_client_ids() to authenticated;

-- ── profiles: owner all; everyone reads/updates own (role-change blocked by the M05 guard) ──
create policy profiles_owner_all on public.profiles for all to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));
create policy profiles_self_read on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ── salon_settings: owner writes; staff reads ──
create policy salon_settings_read on public.salon_settings for select to authenticated
  using ((select private.is_staff_or_owner()));
create policy salon_settings_write on public.salon_settings for all to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));

-- ── catalog: owner writes; staff reads (client/anon read = Stage-2 hook) ──
create policy category_read  on public.category for select to authenticated using ((select private.is_staff_or_owner()));
create policy category_write on public.category for all    to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));
create policy service_read   on public.service  for select to authenticated using ((select private.is_staff_or_owner()));
create policy service_write  on public.service  for all    to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));
create policy product_read   on public.product  for select to authenticated using ((select private.is_staff_or_owner()));
create policy product_write  on public.product  for all    to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));

-- ── staff: read via policy (rate columns already revoked); owner writes ──
create policy staff_read  on public.staff for select to authenticated using ((select private.is_staff_or_owner()));
create policy staff_write on public.staff for all    to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));

-- ── client: owner + staff manage all; a client reads its own row ──
create policy client_staff_all on public.client for all to authenticated
  using ((select private.is_staff_or_owner())) with check ((select private.is_staff_or_owner()));
create policy client_self_read on public.client for select to authenticated
  using (user_id = (select auth.uid()));

-- ── ticket: owner all; staff create/read/update own-involved while open; client reads own ──
create policy ticket_owner_all on public.ticket for all to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));
create policy ticket_staff_read on public.ticket for select to authenticated
  using ((select private.is_staff_or_owner()) and id in (select private.my_ticket_ids()));
create policy ticket_staff_insert on public.ticket for insert to authenticated
  with check ((select private.is_staff_or_owner()) and created_by = (select auth.uid()) and status = 'open');
create policy ticket_staff_update on public.ticket for update to authenticated
  using  ((select private.is_staff_or_owner()) and status = 'open' and id in (select private.my_ticket_ids()))
  with check (status = 'open');
create policy ticket_client_read on public.ticket for select to authenticated
  using (client_id in (select private.my_client_ids()));

-- ── ticket_line: owner all; staff rw on own-involved (open enforced by the M11 guard); client reads own ──
create policy ticket_line_owner_all on public.ticket_line for all to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));
create policy ticket_line_staff_rw on public.ticket_line for all to authenticated
  using  ((select private.is_staff_or_owner()) and ticket_id in (select private.my_ticket_ids()))
  with check ((select private.is_staff_or_owner()) and ticket_id in (select private.my_ticket_ids()));
create policy ticket_line_client_read on public.ticket_line for select to authenticated
  using (ticket_id in (select t.id from public.ticket t where t.client_id in (select private.my_client_ids())));

-- ── money tables: RPC-write-only (only pay_ticket/void_ticket, definer, write them) ──
revoke insert, update, delete on public.payment, public.tip, public.commission_entry, public.stock_movement from authenticated, anon;

-- payment: owner reads all; staff reads own-involved
create policy payment_read on public.payment for select to authenticated
  using ((select private.is_owner()) or ticket_id in (select private.my_ticket_ids()));
-- tip: owner reads all; staff reads own (their tips)
create policy tip_read on public.tip for select to authenticated
  using ((select private.is_owner()) or staff_id = (select private.current_staff_id()));
-- commission_entry: owner reads all; staff reads ONLY their own
create policy commission_read on public.commission_entry for select to authenticated
  using ((select private.is_owner()) or staff_id = (select private.current_staff_id()));
-- stock_movement: owner + staff read
create policy stock_read on public.stock_movement for select to authenticated
  using ((select private.is_staff_or_owner()));
