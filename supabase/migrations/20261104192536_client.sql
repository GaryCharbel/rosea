-- M04 — client (salon customers).
-- Per convention, RLS is enabled at creation (default-deny); policies land in Phase 2.
-- user_id (Stage 2 self-booking) and loyalty_points (Stage 4) are forward hooks,
-- present but unused in Stage 1 (loyalty_points is never mutated yet).

-- ── table ─────────────────────────────────────────────────────────────────────
create table public.client (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(trim(name)) > 0),
  phone          text,
  phone_norm     text generated always as (nullif(regexp_replace(phone, '[^0-9]', '', 'g'), '')) stored, -- digits-only; the uniqueness key
  email          text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  notes          text,
  user_id        uuid unique references auth.users(id) on delete set null, -- Stage 2 hook
  loyalty_points integer not null default 0 check (loyalty_points >= 0),   -- Stage 4 hook (never mutated now)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ── RLS: enabled from day one (default-deny); policies in Phase 2 / M-rls ───────
alter table public.client enable row level security;

-- ── updated_at trigger ─────────────────────────────────────────────────────────
create trigger trg_client_updated before update on public.client
  for each row execute function public.set_updated_at();

-- ── lookup indexes (front desk searches by phone / email) ───────────────────────
-- phone_norm (digits only) is the unique identifier when provided, so '03-111222',
-- '03 111 222' and '03111222' all collide. phone stays nullable, so walk-ins without
-- a phone are still allowed (Postgres treats NULLs as distinct → many null OK; only
-- duplicate normalized phones are rejected). Note: this normalizes formatting, not
-- country-code equivalence (e.g. '+9613...' vs local '03...' are not unified).
create unique index idx_client_phone_norm on public.client(phone_norm);
create index idx_client_email on public.client(lower(email));
