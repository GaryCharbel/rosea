# Rosea Platform — Design Spec (Foundation + Stage 1)

## 1. Overview

**Rosea** is a beauty-salon platform built free for the owners (friends); they pay only running costs (Supabase Pro ~$25/mo + domain ~$15/yr). Three products eventually sit on **one Supabase backend**:

1. Public booking website (Next.js/Vercel) — **deferred**
2. POS (Flutter — **Windows desktop + Android APK** from one codebase) — **built in this slice**
3. Backoffice dashboard (Next.js) — **deferred**

Backend: Supabase (Postgres + Auth + Realtime + Storage + Edge Functions). New codebase, familiar patterns. **Repos: hybrid** — `rosea` (supabase + web + docs) and `rosea-pos` (Flutter). Binding conventions live in each repo's `CLAUDE.md`.

This spec is the single, internally consistent contract for **Foundation + Stage 1**. It supersedes the five source pillars wherever they disagreed; every conflict flagged in the cross-cutting notes is resolved here with one canonical decision and propagated across schema, auth/RLS, commission engine, POS, and tests.

## 2. Scope

### In scope (built now)
- **Foundation:** Supabase schema baseline; Auth with roles `owner`/`staff`/`client`; RLS on every table; `salon_settings` singleton.
- **Stage 1 POS core:** catalog (services, products, categories); staff + per-staff commission rates; tickets with per-line performer; split payments (cash/card/other); per-staff tips; printed receipt; the commission engine (`pay_ticket` + `void_ticket`); a minimal owner commission-summary + cash-up screen in the POS.
- **Flutter desktop POS** implementing the above with "light" resilience (read-through catalog cache + idempotent retry; no offline selling engine).

### Deferred (hooks only — present in schema/architecture, NOT implemented)
- Booking website; online booking (`ticket.appointment_id`, `service.bookable_online`, `service.duration_minutes`, `client.user_id`, client-self RLS).
- Offers: discounts beyond per-line amount, promo codes, packages, gift cards (`payment_method` enum extension), memberships.
- Loyalty (`client.loyalty_points`, `salon_settings.loyalty_enabled`).
- Backoffice dashboard and full report export/column-picker (the POS ships only a minimal owner read-out).
- Multi-location (everything keyed by UUID so a `location` table drops in later).
- Staff PIN fast-switch (Stage 1.5 — see §7.3).
- Tax (`salon_settings.tax_rate` present, fixed 0, no tax line in Stage 1 — see §6.6).

## 3. Resolved cross-cutting decisions (the canonical contract)

These resolutions are binding; the rest of the spec is written to them.

1. **Pay path = one direct Postgres RPC.** `public.pay_ticket(p_ticket_id uuid, p_payments jsonb, p_tips jsonb, p_client_tx uuid)` — `SECURITY DEFINER`, called directly from Flutter via `supabase.rpc('pay_ticket', ...)`. **No Edge Function** for payment. The auth-rls pillar's `settle_ticket` Edge path is dropped. Idempotency via `p_client_tx` stamped into `ticket.paid_tx` (unique) plus a `pg_advisory_xact_lock(ticket_id)`. The schema pillar's wipe-and-recreate-children idempotency is dropped.
2. **Error reporting = P-codes + actionable message.** Every `RAISE` uses a stable token the client matches (`P0001`..`P0005`) via `errcode`, and an actionable `MESSAGE` + `HINT`. The Flutter error mapper and pgTAP assertions key on these codes.
3. **Performer identity = `staff.id`** (the staff PK), never `auth.users.id`. `ticket_line.performer_staff_id` and `commission_entry.staff_id` reference `public.staff(id)`. RLS resolves the caller's staff via `private.current_staff_id()` (reads `profiles.staff_id` for `auth.uid()`).
4. **Helper functions = one set in a `private` schema, defined in migration #1:** `private.current_role()`, `private.is_owner()`, `private.is_staff_or_owner()`, `private.current_staff_id()`. All other helper names (`my_role`, `is_staff`, `jwt_role`, `user_role`) are deleted.
5. **Money = `numeric(12,2)` decimals at the DB boundary.** Rates = `numeric(5,2)` **percent** (`35.00` = 35%); commission = `round(base * rate / 100, 2)`. The Flutter POS may use integer cents internally but a single `money.dart` codec converts cents→decimal (2dp) before any RPC send and decimal→cents on read.
6. **Product commission rate lives on the STAFF member.** A product line earns only if `product.commission_eligible = true` AND `staff.product_commission_rate IS NOT NULL`; rate = `staff.product_commission_rate`. If null → 0. No `product.product_commission_rate`, no `salon_settings.default_product_commission_rate`.
7. **Ticket lifecycle = INCREMENTAL.** Staff directly INSERT an open `ticket` and its `ticket_line` rows via RLS while ringing up. `pay_ticket` operates on the already-persisted open ticket (reads its lines, writes money/commission/stock, flips status). The POS outbox references an already-created server ticket id; it does not ship the whole ticket to `pay_ticket`.
8. **Money tables are RPC-write-only.** `payment`, `tip`, `commission_entry`, `stock_movement` reject all direct `authenticated` writes (`using(false) with check(false)` + REVOKE). Only `pay_ticket`/`void_ticket` (definer-owned, bypass RLS) write them.
9. **`salon_settings` singleton** = `id integer generated always as identity check (id = 1)`, one seeded row. Columns: `name`, `currency`, `timezone`, `address`, `tax_rate` (hook), `loyalty_enabled` (hook), `receipt_header`, `receipt_footer`.
10. **Stock = oversell ALLOWED.** `product.stock_quantity integer` may go negative; `pay_ticket` decrements unconditionally and never blocks a sale on stock. Negatives are surfaced in reporting. (Owner-confirmable; default = allow-oversell per brief spirit "a miscount must never block a sale.")
11. **Void = ledger-style reversal.** `payment.amount`/`tip.amount` CHECK `<> 0`. `void_ticket` posts negative `payment`, negative `tip`, negative `commission_entry` rows + restores stock, stamped with `void_tx` (unique). Nothing deleted.
12. **Discount = per-line amount named `line_discount`.** `line_total` is a GENERATED STORED column: `round(unit_price*qty,2) - line_discount`, CHECK `line_discount <= round(unit_price*qty,2)`. No `tg_line_total` trigger. `ticket.discount_total` = sum of line discounts, set by `pay_ticket`.
13. **Cash change = display-only; ledger stays exact.** `payment.amount` stores the amount APPLIED to the ticket; `sum(payment.amount) = ticket.total` exactly. Cash overpayment/change is computed and printed client-side only (never stored as tender). The POS sends applied amounts (capped), not tendered.
14. **Tips ride on a payment tender for reconciliation, but are stored as separate per-staff `tip` rows.** To close the cash-up gap: each element of `p_payments` may carry an optional `tip_amount` and `tip_staff_id`; `pay_ticket` splits them into (a) a `payment` row of `amount` (service/product money, summing to total) and (b) a `tip` row keyed to the staff member. The receipt and cash-up reconcile total tendered = `sum(payment.amount) + sum(tip.amount)` per method. `p_tips` also accepts standalone tips not tied to a tender. Tips never enter commission or the balance check.
15. **Ticket number** = `ticket.ticket_no bigint generated always as identity` (may gap). No separate sequence+trigger. Receipt/RPC-result field = `ticket_no`.
16. **Migration naming** = Supabase CLI timestamped files (`supabase migration new <name>`). The 0001–0018 numbering is logical ordering only. `private.*` helpers live in migration #1.
17. **Staff rates are invisible to cashiers.** Column-level `REVOKE SELECT (commission_rate, product_commission_rate) ON public.staff FROM authenticated`, plus a `staff_public` view exposing `id, name, title, active` for the POS. Owner reads full `staff` via a `SECURITY DEFINER` path or owner-only policy on a rate view. No commission math or rates on the shared till.

## 4. Architecture

```
┌──────────────────────── Supabase (one project) ────────────────────────┐
│  Postgres:  public (app tables) + private (SECURITY DEFINER helpers)    │
│  Auth:      email+password, roles owner/staff/client via profiles       │
│  RLS:       every table; catalog read-open to authenticated;            │
│             money tables RPC-write-only; staff rates column-revoked      │
│  RPCs:      pay_ticket / void_ticket (SECURITY DEFINER, definer-owned)   │
│  Realtime:  not required Stage 1 (polling-on-focus); hook present        │
│  Storage:   image_url columns (hook); not wired Stage 1                  │
│  Functions: send-email stub (channel seam, verify_jwt=false)             │
└─────────────────────────────────────────────────────────────────────────┘
        ▲ publishable key + user JWT (authenticated)
        │
┌───────┴─────────── Flutter Windows POS (rosea_pos) ─────────────────────┐
│  Riverpod 3 (codegen) state; Drift SQLite catalog cache + outbox        │
│  Direct supabase.rpc('pay_ticket', ...); idempotent retry on blip       │
│  PDF receipt via pdf + printing; bold/elevated UI                        │
└─────────────────────────────────────────────────────────────────────────┘
   (deferred: Next.js booking site, Next.js dashboard — same backend)
```

The backend is the shared contract. Monorepo (`rosea/`) with `supabase/` (source of truth), `pos/` (Flutter), `web/` (placeholder README), `docs/`.

## 5. Data model (consolidated DDL)

Conventions: PKs `uuid default gen_random_uuid()` except `profiles.id = auth.users.id` and `salon_settings.id` identity singleton. Money `numeric(12,2)`. Rates `numeric(5,2)` percent, CHECK 0–100. `created_at` everywhere; `updated_at` + shared `set_updated_at()` on mutable catalog/config. Soft-delete (`active`) for catalog/staff; transactional rows immutable once a ticket leaves `open`.

### 5.1 Migration M01 — enums + helpers (the FIRST migration)

```sql
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create type public.user_role      as enum ('owner','staff','client');
create type public.category_kind  as enum ('service','product');
create type public.ticket_status  as enum ('open','paid','void');
create type public.line_type      as enum ('service','product');
create type public.payment_method as enum ('cash','card','other'); -- 'gift_card' added in Stage 3
create type public.stock_reason   as enum ('sale','adjustment','restock','void_restore');

create or replace function public.set_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

-- Helpers live here (migration #1) so early triggers/policies can rely on them.
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
create or replace function private.current_staff_id() returns uuid
  language sql stable security definer set search_path = '' as $$
  select staff_id from public.profiles where id = (select auth.uid()); $$;
grant execute on function private.current_role(), private.is_owner(),
  private.is_staff_or_owner(), private.current_staff_id() to authenticated;
```
> Note: `private.current_role()` falls back to a `profiles` read when the JWT claim is absent (first login before claim refresh). `profiles` must not be `force row level security`; helpers are definer-owned by a `bypassrls` role.

### 5.2 M02 — salon_settings (singleton)

```sql
create table public.salon_settings (
  id             integer primary key generated always as identity check (id = 1),
  name           text not null default 'Rosea',
  currency       text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  timezone       text not null default 'UTC',
  address        text,
  tax_rate       numeric(5,2) not null default 0 check (tax_rate between 0 and 100), -- HOOK (Stage 3), fixed 0 now
  loyalty_enabled boolean not null default false,                                    -- HOOK (Stage 4)
  receipt_header text,
  receipt_footer text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger trg_salon_settings_updated before update on public.salon_settings
  for each row execute function public.set_updated_at();
insert into public.salon_settings (name) values ('Rosea'); -- id = 1
```

### 5.3 M03 — staff

```sql
create table public.staff (
  id                      uuid primary key default gen_random_uuid(),
  name                    text not null check (length(trim(name)) > 0),
  title                   text,
  commission_rate         numeric(5,2) not null default 0 check (commission_rate between 0 and 100),
  product_commission_rate numeric(5,2) check (product_commission_rate is null or product_commission_rate between 0 and 100),
  active                  boolean not null default true,
  user_id                 uuid unique references auth.users(id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create trigger trg_staff_updated before update on public.staff
  for each row execute function public.set_updated_at();
create index idx_staff_active on public.staff(active) where active;

-- Cashier-safe view (NO rate columns). The POS caches from this, never from public.staff.
create view public.staff_public as
  select id, name, title, active from public.staff;
```

### 5.4 M04 — client

```sql
create table public.client (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(trim(name)) > 0),
  phone          text,
  email          text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  notes          text,
  user_id        uuid unique references auth.users(id) on delete set null, -- Stage 2 hook
  loyalty_points integer not null default 0 check (loyalty_points >= 0),   -- Stage 4 hook (never mutated now)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create trigger trg_client_updated before update on public.client
  for each row execute function public.set_updated_at();
create index idx_client_phone on public.client(phone);
create index idx_client_email on public.client(lower(email));
```

### 5.5 M05 — profiles + auth bridge

```sql
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.user_role not null default 'client',
  staff_id   uuid unique references public.staff(id)  on delete set null,
  client_id  uuid unique references public.client(id) on delete set null,
  full_name  text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_role_link_chk check (
        (role='owner'  and staff_id is null and client_id is null)
     or (role='staff'  and staff_id is not null and client_id is null)
     or (role='client' and staff_id is null))
);
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Anti-escalation: only an owner may change role/links.
create or replace function public.guard_profile_role_change() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  if (new.role, new.staff_id, new.client_id) is distinct from (old.role, old.staff_id, old.client_id)
     and private.current_role() <> 'owner' then
    raise exception 'Only an owner can change a user''s role or staff/client link. Ask the owner to update this account.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end; $$;
create trigger trg_profiles_guard_role before update on public.profiles
  for each row execute function public.guard_profile_role_change();

create or replace function public.set_user_role(
  p_user_id uuid, p_role public.user_role, p_staff_id uuid default null, p_client_id uuid default null)
  returns void language plpgsql security definer set search_path = '' as $$
begin
  if private.current_role() <> 'owner' then
    raise exception 'Only an owner can assign roles.' using errcode = 'insufficient_privilege'; end if;
  update public.profiles set role=p_role, staff_id=p_staff_id, client_id=p_client_id where id=p_user_id;
  if not found then
    raise exception 'No profile for user %. The user must sign in once before being assigned a role.', p_user_id
      using errcode = 'no_data_found'; end if;
end; $$;
revoke execute on function public.set_user_role(uuid, public.user_role, uuid, uuid) from public, anon;
grant  execute on function public.set_user_role(uuid, public.user_role, uuid, uuid) to authenticated;

-- JWT custom claim (role + staff_id) — registered in Dashboard → Auth → Hooks.
create or replace function public.custom_access_token_hook(event jsonb) returns jsonb
  language plpgsql stable security definer set search_path = '' as $$
declare claims jsonb := event->'claims'; r public.user_role; sid uuid;
begin
  select p.role, p.staff_id into r, sid from public.profiles p where p.id = (event->>'user_id')::uuid;
  if r is not null then
    claims := jsonb_set(claims, '{user_role}', to_jsonb(r::text));
    claims := jsonb_set(claims, '{staff_id}',  coalesce(to_jsonb(sid::text),'null'::jsonb));
  end if;
  return jsonb_set(event, '{claims}', claims);
end; $$;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on table public.profiles to supabase_auth_admin;
```
**Production first-owner bootstrap (one-time, manual):** the owner signs up (becomes `client`), then run as service_role in the Dashboard SQL editor: `update public.profiles set role='owner' where id='<owner auth uid>';`. Documented in `docs/runbook.md`. Local dev seeds this automatically.

### 5.6 M06–M08 — catalog

```sql
-- category
create table public.category (
  id uuid primary key default gen_random_uuid(),
  kind public.category_kind not null,
  name text not null check (length(trim(name)) > 0),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (kind, name));
create trigger trg_category_updated before update on public.category
  for each row execute function public.set_updated_at();
create index idx_category_kind on public.category(kind, sort_order) where active;

-- service (bookable_online + duration_minutes are Stage-2 hooks)
create table public.service (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.category(id) on delete set null,
  name text not null check (length(trim(name)) > 0),
  description text,
  price numeric(12,2) not null check (price >= 0),
  duration_minutes integer not null default 30 check (duration_minutes > 0),
  image_url text,
  active boolean not null default true,
  bookable_online boolean not null default false,  -- HOOK Stage 2
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create trigger trg_service_updated before update on public.service
  for each row execute function public.set_updated_at();
create index idx_service_active on public.service(category_id, sort_order) where active;
-- kind guard trigger: category must be kind 'service' (actionable raise)

-- product (commission_eligible gates product commission; oversell allowed → no >=0 CHECK on stock)
create table public.product (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.category(id) on delete set null,
  name text not null check (length(trim(name)) > 0),
  description text,
  price numeric(12,2) not null check (price >= 0),
  sku text unique,
  image_url text,
  track_stock boolean not null default false,
  stock_quantity integer not null default 0,     -- may go negative; flagged in reports
  commission_eligible boolean not null default true,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create trigger trg_product_updated before update on public.product
  for each row execute function public.set_updated_at();
create index idx_product_active on public.product(category_id, sort_order) where active;
-- kind guard trigger: category must be kind 'product'
```

### 5.7 M09–M10 — ticket

```sql
create table public.ticket (
  id uuid primary key default gen_random_uuid(),
  ticket_no bigint generated always as identity,    -- human receipt #, may gap
  status public.ticket_status not null default 'open',
  opened_by uuid not null references public.staff(id) on delete restrict,
  created_by uuid not null default (select auth.uid()) references public.profiles(id), -- for ownership RLS
  client_id uuid references public.client(id) on delete set null,
  appointment_id uuid,                              -- HOOK Stage 2, pinned null
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  total numeric(12,2) not null default 0 check (total >= 0),
  paid_tx uuid unique,                              -- idempotency: client_tx that paid it
  void_tx uuid unique,                              -- idempotency: client_tx that voided it
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ticket_closed_at_chk check ((status='open' and closed_at is null) or (status<>'open' and closed_at is not null)),
  constraint ticket_appointment_stage1 check (appointment_id is null));
create trigger trg_ticket_updated before update on public.ticket
  for each row execute function public.set_updated_at();
create index idx_ticket_status_opened on public.ticket(status, opened_at desc);
create index idx_ticket_client on public.ticket(client_id);
create index idx_ticket_closed_at on public.ticket(closed_at desc) where status='paid';
```

### 5.8 M11 — ticket_line (performer-per-line) + immutability guards

```sql
create table public.ticket_line (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.ticket(id) on delete cascade,
  line_type public.line_type not null,
  service_id uuid references public.service(id) on delete restrict,
  product_id uuid references public.product(id) on delete restrict,
  name_snapshot text not null,
  unit_price numeric(12,2) not null check (unit_price >= 0),
  qty numeric(10,3) not null default 1 check (qty > 0),
  line_discount numeric(12,2) not null default 0 check (line_discount >= 0),
  line_total numeric(12,2) generated always as (round(unit_price*qty,2) - line_discount) stored,
  performer_staff_id uuid not null references public.staff(id) on delete restrict,
  commission_rate_snapshot numeric(5,2) check (commission_rate_snapshot between 0 and 100),
  commission_amount numeric(12,2) check (commission_amount >= 0),
  created_at timestamptz not null default now(),
  constraint ticket_line_discount_chk check (line_discount <= round(unit_price*qty,2)),
  constraint ticket_line_kind_chk check (
      (line_type='service' and service_id is not null and product_id is null)
   or (line_type='product' and product_id is not null and service_id is null)),
  constraint ticket_line_product_whole_qty check (line_type <> 'product' or qty = trunc(qty)));
create index idx_ticket_line_ticket on public.ticket_line(ticket_id);
create index idx_ticket_line_performer on public.ticket_line(performer_staff_id);

-- Immutability: children of a non-open ticket are frozen (corrections = void).
create or replace function public.guard_child_only_when_open() returns trigger
  language plpgsql as $$
declare v_status public.ticket_status;
begin
  select status into v_status from public.ticket where id = coalesce(new.ticket_id, old.ticket_id);
  if v_status is distinct from 'open' then
    raise exception 'Ticket is already closed; it cannot be modified. Void it and start a new ticket to make a correction.'
      using errcode = 'check_violation'; end if;
  return coalesce(new, old);
end; $$;
create trigger trg_line_open before insert or update or delete on public.ticket_line
  for each row execute function public.guard_child_only_when_open();
```
> `pay_ticket` inserts payments/tips while the ticket is still `open`, so these guards pass; it flips status to `paid` last.

### 5.9 M12–M15 — payment, tip, commission_entry, stock_movement

```sql
create table public.payment (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.ticket(id) on delete cascade,
  method public.payment_method not null,
  amount numeric(12,2) not null check (amount <> 0),  -- amount APPLIED to ticket; negative on void reversal
  reference text,
  taken_by uuid not null references public.staff(id) on delete restrict,
  client_tx uuid not null,
  created_at timestamptz not null default now());
create index idx_payment_ticket on public.payment(ticket_id);
create index idx_payment_method_date on public.payment(method, created_at); -- cash-up
create trigger trg_payment_open before insert or update or delete on public.payment
  for each row execute function public.guard_child_only_when_open();

create table public.tip (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.ticket(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete restrict,
  amount numeric(12,2) not null check (amount <> 0),  -- negative on void reversal
  method public.payment_method,                       -- how the tip was tendered (for cash-up)
  client_tx uuid not null,
  created_at timestamptz not null default now());
create index idx_tip_ticket on public.tip(ticket_id);
create index idx_tip_staff_date on public.tip(staff_id, created_at);
create trigger trg_tip_open before insert or update or delete on public.tip
  for each row execute function public.guard_child_only_when_open();

create table public.commission_entry (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.staff(id) on delete restrict,
  ticket_id uuid not null references public.ticket(id) on delete restrict,
  ticket_line_id uuid not null references public.ticket_line(id) on delete restrict,
  line_type public.line_type not null,
  base_amount numeric(12,2) not null,                 -- = line_total; negative on reversal
  rate numeric(5,2) not null check (rate between 0 and 100),
  amount numeric(12,2) not null,                      -- round(base*rate/100,2); negative on reversal
  is_reversal boolean not null default false,
  earned_at timestamptz not null default now(),
  created_at timestamptz not null default now());
create unique index uq_commission_line_earning on public.commission_entry(ticket_line_id) where not is_reversal;
create unique index uq_commission_line_reversal on public.commission_entry(ticket_line_id) where is_reversal;
create index idx_commission_staff_earned on public.commission_entry(staff_id, earned_at);
create index idx_commission_ticket on public.commission_entry(ticket_id);

create table public.stock_movement (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.product(id) on delete restrict,
  reason public.stock_reason not null,
  qty_delta integer not null check (qty_delta <> 0),  -- negative for a sale
  ticket_id uuid references public.ticket(id) on delete set null,
  note text,
  created_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now());
create index idx_stock_movement_product on public.stock_movement(product_id, created_at);
```

## 6. Auth, roles & RLS

### 6.1 Identity
One `auth.users` ↔ one `profiles` row (auto-created by `handle_new_user`, default `client`). `profiles.role` drives authorization; `profiles.staff_id` bridges to the `staff` PK (the performer identity). Role mirrored into JWT (`user_role`, `staff_id`) via the Custom Access Token hook; helpers fall back to a `profiles` read when the claim is stale.

### 6.2 RLS matrix (Stage 1)

| Table | owner | staff | client | anon |
|---|---|---|---|---|
| `profiles` | all | read own + role via owner; self-update non-privilege fields | read/update own (non-role) | – |
| `salon_settings` | all | read | – | – |
| `category`/`service`/`product` | all | read | – (Stage-2 anon read hook) | – |
| `staff` | all (incl. rates) | read via `staff_public` only (rates column-revoked) | – | – |
| `client` | all | all | read own | – |
| `ticket` | all | create/read/update own-involved **while open** | read own (via client link) | – |
| `ticket_line` | all | create/update on open own-involved tickets | read own ticket's lines | – |
| `payment` | read all | read own-involved; **no write** | – | – |
| `tip` | read all | read own; **no write** | – | – |
| `commission_entry` | read all | **read OWN only**; no write | – | – |
| `stock_movement` | read all | read; no write | – | – |

Key RLS SQL (all policies `to authenticated`; `(select private.fn())` for initplan caching):

```sql
-- staff rates invisible to cashiers (column-level), POS reads staff_public
revoke select (commission_rate, product_commission_rate) on public.staff from authenticated;
grant select on public.staff_public to authenticated;

-- staff: read needs the view; owner reads full staff row
alter table public.staff enable row level security;
create policy staff_read on public.staff for select to authenticated using ( (select private.is_staff_or_owner()) );
create policy staff_write on public.staff for all to authenticated
  using ( (select private.is_owner()) ) with check ( (select private.is_owner()) );

-- ticket own-involved helper (performer resolves to staff.id)
create or replace function private.my_ticket_ids() returns setof uuid
  language sql stable security definer set search_path = '' as $$
  select t.id from public.ticket t where t.created_by = (select auth.uid())
  union
  select tl.ticket_id from public.ticket_line tl where tl.performer_staff_id = private.current_staff_id();
$$;
grant execute on function private.my_ticket_ids() to authenticated;

-- commission_entry: owner all; staff only their own (keyed to staff.id)
alter table public.commission_entry enable row level security;
create policy comm_read on public.commission_entry for select to authenticated
  using ( (select private.is_owner()) or staff_id = (select private.current_staff_id()) );
create policy comm_no_write on public.commission_entry for all to authenticated using (false) with check (false);

-- money tables RPC-write-only
revoke insert, update, delete on public.payment, public.tip, public.commission_entry, public.stock_movement from authenticated, anon;
-- + read policies (staff/owner) and using(false) write policies per the matrix
```

### 6.3 Pay-path security
`pay_ticket`/`void_ticket` are `SECURITY DEFINER`, owned by a `bypassrls` role, and **self-authorize** (`if not private.is_staff_or_owner() then raise insufficient_privilege`). Execute is granted to `authenticated` but the in-function role gate is the real guard (website clients also hold `authenticated`). Void is owner-only.

### 6.4 RLS pitfalls explicitly closed
No broad staff read on `commission_entry`; no `to public` policies; no direct money writes; no recursive `profiles` policy (helpers are definer, no `force rls`); `(select fn())` wrapping; a `get_advisors` security run asserts RLS on every public table before merge.

### 6.5 Staff sign-in (Stage 1 baseline)
Email+password, one real Supabase account per staff member → distinct `auth.uid()` → `profiles.staff_id` → correct performer credit + own-commission RLS. Session persists to desktop secure storage. **No PIN in Stage 1** — the POS does NOT call `verify_pin` (that subsystem is Stage 1.5; see §7.3). Performer-per-line is chosen in the UI from `staff_public`; the signed-in account is the writer of record.

### 6.6 Tax
Stage 1: `tax_rate` fixed `0`, **no tax line computed**, no `tax_total` column on `ticket`. Commission base is the post-discount line total (pre-tax by definition, since tax is 0). The receipt shows no tax line in Stage 1. `salon_settings.tax_rate` remains as a Stage-3 hook.

## 7. Commission engine (`pay_ticket`)

### 7.1 Contract
```
public.pay_ticket(p_ticket_id uuid, p_payments jsonb, p_tips jsonb, p_client_tx uuid) returns jsonb
-- p_payments: [{"method":"cash","amount":45.00,"reference":null,
--               "tip_amount":5.00,"tip_staff_id":"<staff uuid>"}...]  (tip_* optional)
-- p_tips:     [{"staff_id":"<uuid>","amount":5.00,"method":"card"}...]  (standalone tips; may be [])
-- p_client_tx: uuid minted once per checkout attempt, reused on retry (idempotency key)
```
Called directly from Flutter. `SECURITY DEFINER`, `set search_path=''`, schema-qualified relations.

### 7.2 Algorithm (one transaction)
1. **Authz:** `private.is_staff_or_owner()` else raise `insufficient_privilege` (token not needed — RLS-class).
2. **Shape validation:** `p_client_tx` not null; `p_payments`/`p_tips` are arrays — else `P0002`/actionable.
3. **Advisory lock:** `pg_advisory_xact_lock(hashtextextended(p_ticket_id::text,0))` (serialize same-ticket).
4. **Load+lock ticket** `for update`. Not found → `P0001`-class actionable.
5. **Idempotent replay:** if `status='paid'` and `paid_tx = p_client_tx` → return `_pay_ticket_result` (no-op). If `paid` with a different key → `P0001` "already paid". If `void` → `P0001` "voided, cannot be paid".
6. **Recompute totals** from `ticket_line` (never trust client): `subtotal = sum(round(unit_price*qty,2))`, `discount_total = sum(line_discount)`, `total = sum(line_total)`.
7. **Empty-ticket guard:** no lines / `total <= 0` with non-empty payments → `P0004`. (A fully-discounted `total = 0` ticket is payable with empty payments.)
8. **Split-payment validation:** `sum(payment.amount applied) = total` exactly → else `P0002` with the difference and an actionable hint. (Applied amounts only; cash change is client-side display.)
9. **Insert payments** (the `amount` field = applied), tagged `client_tx`. For each payment element carrying `tip_amount > 0`, also insert a `tip` row (`staff_id = tip_staff_id`, `method = payment.method`).
10. **Insert standalone tips** from `p_tips`.
11. **Commission:** per line resolve rate — service → `staff.commission_rate`; product → `staff.product_commission_rate` only if `product.commission_eligible` AND that rate is non-null, else 0. Freeze `commission_rate_snapshot` + `commission_amount = round(line_total*rate/100,2)` on the line; insert one `commission_entry` per line where `rate > 0` (`base_amount = line_total`). Zero-rate lines get no entry (or an amount-0 entry for audit — choose amount-0 for completeness; unique index tolerates one per line).
12. **Stock:** for tracked product lines, `stock_quantity -= qty` **unconditionally** (oversell allowed, may go negative) and insert a `sale` `stock_movement`.
13. **Flip** `status='paid'`, set `subtotal/discount_total/total`, `paid_tx=p_client_tx`, `closed_at=now()`.
14. **Return** `_pay_ticket_result(p_ticket_id)` (see §7.4).

`void_ticket(p_ticket_id, p_reason, p_client_tx)` — owner-only. Idempotent via `void_tx`. Posts negative `commission_entry` (is_reversal), negative `payment`, negative `tip`, and `void_restore` stock movements (+units); flips `paid→void`. Raises `P0001`-class if not paid.

### 7.3 Staff PIN (Stage 1.5, deferred)
Not built in Stage 1. If added: `staff_pin(staff_id, pin_hash)` (bcrypt via pgcrypto), RLS `using(false)`, a `verify_pin(staff_id,pin)` `SECURITY DEFINER` RPC revoked from `authenticated`, attempt-lockout. The PIN gates attribution only, never escalates the JWT. The Stage-1 POS does not reference it.

### 7.4 Receipt payload contract (`_pay_ticket_result`, definer, revoked from clients)
Returns everything the receipt needs so no second round-trip is required post-pay, and no rate/commission leak:
```json
{
  "ticket_id":"...", "ticket_no": 1001, "status":"paid",
  "subtotal": 196.00, "discount_total": 9.00, "total": 196.00, "closed_at":"...",
  "salon": {"name":"...","address":"...","receipt_header":"...","receipt_footer":"...","currency":"USD"},
  "lines": [{"name":"Women's Cut","line_type":"service","performer_name":"Maya",
             "unit_price":45.00,"qty":1,"line_discount":9.00,"line_total":36.00}, ...],
  "payments": [{"method":"cash","amount":100.00},{"method":"card","amount":96.00}],
  "tips": [{"staff_name":"Lea","amount":10.00,"method":"card"}],
  "tip_total": 10.00
}
```
`performer_name`/`staff_name` are resolved server-side (join to `staff.name`), so the receipt never needs cached rates. Commission is **not** in the receipt payload.

### 7.5 Error codes
| Token (errcode) | When | Flutter copy |
|---|---|---|
| `P0001` | ticket not open / already paid / voided / not found | "This ticket is already paid. Open a new ticket to ring up more." (variant per message) |
| `P0002` | `sum(payment.amount) ≠ total` | "Payments total X but the ticket is Y. Adjust the split so it matches." |
| `P0004` | no lines | "Add at least one service or product before taking payment." |
| `insufficient_privilege` | non-staff caller / non-owner void | "Only salon staff can take payments." / "Only an owner can void a ticket." |
Every raise carries both the token (matched by the client) and an actionable message + hint. No `P0003` (insufficient-stock) in Stage 1 because oversell is allowed.

### 7.6 Test matrix (pgTAP, keyed to resolved rules)
Fixtures: Staff **S1** `commission_rate=40.00`, `product_commission_rate=10.00`; **S2** both 0/null. Product **P_elig** `commission_eligible=true, track_stock=true, stock=10`; **P_noelig** `commission_eligible=false`. Service **Svc** price 100. All pay calls as owner/staff.

| # | Scenario | Expected |
|---|---|---|
| 1 | Svc 100 (S1) → pay [{card,100}] | 1 entry: service 40.00 (100×40%); paid |
| 2 | Svc 100 (S1) + P_elig 1×50 (S1) → pay [{cash,150}] | entries 40.00 + 5.00 (50×10%); P_elig 10→9; paid |
| 3 | P_noelig 1×40 (S1) → pay [{card,40}] | entry amount 0 (not eligible); stock 10→9; paid |
| 4 | Svc 100 (S1) → pay [{cash,40},{card,60}] | entry 40.00; 2 payment rows; paid 100 |
| 5 | Svc unit 100, line_discount 100 → total 0 → pay [] | entry base 0, amount 0; paid total 0 |
| 6 | Svc 100 (S1) → pay [{card,100,tip 10 to S1}] | entry 40.00; tip row 10 for S1; payment sum 100; paid |
| 7 | Svc 100 → pay [{cash,90}] | rolled back, `P0002`, actionable |
| 8 | Svc 100 → pay [{cash,120}] | rolled back, `P0002` (applied ≠ total; overpay is display-only, so applied=120≠100 fails) |
| 9 | S2 performs Svc 100 → pay [{cash,100}] | entry amount 0 (rate 0); paid |
| 10 | P_elig qty 15 (stock 10) → pay [{cash,750}] | **succeeds**, stock 10→**-5** (oversell allowed) |
| 11 | Case 1 then re-call with same `p_client_tx` | still exactly 1 entry, no new payment; identical result (idempotent) |
| 12 | Two concurrent pays, different keys | one wins; loser blocks then raises `P0001` already-paid |
| 13 | Client role calls pay_ticket | rolled back, `insufficient_privilege` |
| 14 | void_ticket (owner) after case 2 | 2 negative reversal entries (net 0 per staff); P_elig 9→10; status void |
| 15 | void_ticket replay same key | no new rows; different key → `P0001` already-voided; staff caller → `insufficient_privilege` |
| 16 | eligible product, S1 `product_commission_rate=null` | product entry amount 0 (null → 0, never falls back to service rate) |
| 17 | rounding: line base 16.70 @ 33.50% | commission 5.59 (16.70×0.335=5.5945 → half-up 5.59) |

## 8. Flutter desktop POS

### 8.1 Stack
Riverpod 3 (codegen) for state; Drift (SQLite) for the read-through catalog cache + durable pay outbox; `supabase_flutter` ≥ 2.x (publishable key only); `go_router` (sync boot redirect); `pdf` + `printing` for receipts; `uuid`, `connectivity_plus`, `jwt_decoder`.

### 8.2 State model
- `CheckoutDraft` (`Notifier`): lines (each with `performerStaffId`, `lineDiscountCents`), payments, tips.
- `ticketTotals` (derived): subtotal, discount, net, paid (applied), `changeDueCents = max(0, cashTendered - net)` (display only), remaining.
- Catalog/staff: `StreamProvider` over Drift `.watch()` (from `service`, `product`, `category`, `staff_public` — **no rates cached**).
- `SessionController` (`AsyncNotifier`): auth via `signInWithPassword`, sealed `AuthState` handling, `AuthApiException` mapping.
- `PayController` + `OutboxController`: durable intent → RPC flush → retry.
- Owner-only `ticketCommissionProvider` reads commission back from the server (never a client recompute).

### 8.3 Ring-up → pay flow (INCREMENTAL lifecycle)
1. Cashier opens a ticket → POS inserts an open `ticket` (status open) server-side immediately (RLS allows staff insert; gets `ticket_no`).
2. As lines are added, POS inserts `ticket_line` rows (performer-per-line) via RLS.
3. On Pay: `PayValidator` runs client-side (actionable, pre-network); mint `p_client_tx` once; write a durable outbox row referencing the server ticket id; flush = `supabase.rpc('pay_ticket', {p_ticket_id, p_payments (applied amounts, cents→decimal), p_tips, p_client_tx})`.
4. On success: parse `_pay_ticket_result` → print receipt → clear draft. On transient/offline: outbox retries with the **same** `p_client_tx` (server replays safely). On RLS/validation error: mark failed, show the server's actionable message verbatim, do not auto-retry.

Money codec: `money.dart` converts internal cents → `numeric` decimal (2dp) before send, and parses decimals → cents on read. Unit-tested so no 100× mispay.

### 8.4 Light resilience boundary
Works during a blip: browse cached catalog, build ticket, enter split/tips, tap Pay (queued). Blocks until online: the authoritative total, server ticket #, printed receipt (receipt needs the RPC result), and all owner/catalog edits. **No offline selling** — nothing is "paid" without the server round-trip. Idempotency (`p_client_tx` + `paid_tx` unique + advisory lock + single-flight outbox + boot recovery of `sending`→`pending`) makes retry safe.

### 8.5 Screens
`/login`, `/switch` (performer select from `staff_public` — no PIN in Stage 1, just a chooser), `/checkout` (catalog grid + ticket panel with performer chips + payment sheet with live remaining/change + tip sheet + receipt dialog), `/outbox` (owner: queued pays), `/admin` (owner: catalog/staff-rate edit + **commission-summary & cash-up read-out**).

### 8.6 Minimal owner commission + cash-up screen (closes the reporting gap)
Stage 1 ships a basic **owner-only** screen reading the RLS-protected `commission_entry` and `payment`/`tip`: commission grouped by staff + date range; cash-up totals = `sum(payment.amount)` and `sum(tip.amount)` per method over a date. No PDF/Excel/column-picker yet (that is the dashboard stage), but the owner can reconcile payroll and the till. The customer receipt never shows commission.

### 8.7 Actionable errors
One sealed `AppError{title, detail, action}`. Mappers: `AuthApiException` (400/401 wrong creds, 429 rate-limit), `PostgrestException` by token (`P0001/P0002/P0004`, `insufficient_privilege`/`42501`), transport → "queued, will retry". A unit test asserts every pay token maps to a specific non-generic message; a widget test asserts no "unexpected error" ever surfaces.

### 8.8 Receipt
PDF via `pdf` + `printing` sized to an 80mm roll, printed only after `pay_ticket` returns (needs `ticket_no` + authoritative totals). Shows salon header/footer, lines + performer names, per-line discount, split tenders, tips, change (display), total. Bold/elevated aesthetic; swappable `ReceiptPrinter` interface for a future ESC/POS printer.

## 9. Forward-compat hooks (declared, not built)

| Stage | Hook in schema | Activation (additive only) |
|---|---|---|
| 2 Booking | `service.bookable_online`/`duration_minutes`; `ticket.appointment_id` (pinned null); `client.user_id`; client-self RLS | add `appointment` table; drop `ticket_appointment_stage1`; add FK; anon read policy for bookable services |
| 3 Offers/gift cards | `payment_method` extensible; `line_discount`/`discount_total`; `salon_settings.tax_rate` | `alter type payment_method add value 'gift_card'`; add discount/promo/package/gift_card/membership tables; wire tax |
| 4 Loyalty | `client.loyalty_points`; `salon_settings.loyalty_enabled` | add `loyalty_transaction`; `pay_ticket` credits points when enabled |
| Multi-location | all UUID-keyed; `salon_settings` singleton | add `location` + nullable `location_id` FKs; backfill |
| Channel layer | `supabase/functions/send-email` stub | add `send-whatsapp`/`send-sms` siblings, same signature |
| Staff PIN | `staff_pin`/`verify_pin` (1.5) | add table + RPC + lockout |

## 10. Standing-rule alignment
Review + runtime-test every commit; BE+FE paired and e2e-tested per feature before the next; actionable errors on both sides (P-codes + hints, client mappers); no Claude/AI attribution in commits/branches/PRs (user pushes and opens PRs); bold/elevated UI (figures hero, elevated cards, solid performer chips); reports (later) get export + column picker.
