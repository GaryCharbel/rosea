-- M01 — Foundation: enums + private helper schema (the FIRST migration).
-- Defines the shared enum vocabulary, the updated_at trigger function, and the
-- authorization helpers that every later RLS policy leans on. Per the design
-- spec (§4 resolution #4) the helper set lives here, in migration #1, so early
-- triggers and policies can rely on it.
--
-- Note: private.current_role() / current_staff_id() read public.profiles, which
-- is not created until M05. A `language sql` function body is validated at
-- CREATE time, so we disable body validation around the definitions — the exact
-- mechanism pg_dump uses to restore functions that reference not-yet-created
-- objects. Validation is restored at the end of the migration.
set check_function_bodies = off;

-- ── private schema (never API-exposed) ────────────────────────────────────────
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

-- ── shared enums ──────────────────────────────────────────────────────────────
create type public.user_role      as enum ('owner','staff','client');
create type public.category_kind  as enum ('service','product');
create type public.ticket_status  as enum ('open','paid','void');
create type public.line_type      as enum ('service','product');
create type public.payment_method as enum ('cash','card','other'); -- 'gift_card' added in Stage 3
create type public.stock_reason   as enum ('sale','adjustment','restock','void_restore');

-- ── shared updated_at trigger ─────────────────────────────────────────────────
create or replace function public.set_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

-- ── authorization helpers (SECURITY DEFINER, search_path = '') ────────────────
-- current_role: JWT claim first (fast path), falling back to a profiles read
-- when the claim is absent/stale (first login before claim refresh).
create or replace function private.current_role() returns public.user_role
  language sql stable security definer set search_path = '' as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'user_role','')::public.user_role,
    (select p.role from public.profiles p where p.id = (select auth.uid())));
$$;

create or replace function private.is_owner() returns boolean
  language sql stable security definer set search_path = '' as $$ select private.current_role() = 'owner'; $$;

create or replace function private.is_staff_or_owner() returns boolean
  language sql stable security definer set search_path = '' as $$ select private.current_role() in ('owner','staff'); $$;

-- current_staff_id: the caller's staff PK (performer identity), or null for non-staff.
create or replace function private.current_staff_id() returns uuid
  language sql stable security definer set search_path = '' as $$
  select staff_id from public.profiles where id = (select auth.uid()); $$;

grant execute on function private.current_role(), private.is_owner(),
  private.is_staff_or_owner(), private.current_staff_id() to authenticated;

reset check_function_bodies;
