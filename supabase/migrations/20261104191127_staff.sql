-- M03 — staff + cashier-safe staff_public view.
-- Per the convention from M02 on, RLS is enabled at table creation (default-deny).
-- The access policies, the column-level REVOKE of the rate columns, and the
-- staff_public grants land in the Phase 2 RLS migration (M-rls).

-- ── table ─────────────────────────────────────────────────────────────────────
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

-- ── RLS: enabled from day one (default-deny); policies + rate-column REVOKE in Phase 2 / M-rls ──
alter table public.staff enable row level security;

-- ── updated_at trigger ─────────────────────────────────────────────────────────
create trigger trg_staff_updated before update on public.staff
  for each row execute function public.set_updated_at();

-- ── partial index on active staff (the POS lists active performers) ─────────────
create index idx_staff_active on public.staff(active) where active;

-- ── cashier-safe projection (NO rate columns); the POS caches from this, never public.staff ──
create view public.staff_public as
  select id, name, title, active from public.staff;
