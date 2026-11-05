-- M14 — commission_entry (ledger).
-- One earning row per ticket_line (written by pay_ticket), and at most one reversal
-- row per ticket_line (written by void_ticket, is_reversal=true, negative amounts).
-- RPC-write-only (RLS default-deny now; using(false)+REVOKE in Phase 2). No open-guard:
-- the reversal is written while the ticket is already paid/void.
create table public.commission_entry (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references public.staff(id) on delete restrict,
  ticket_id      uuid not null references public.ticket(id) on delete restrict,
  ticket_line_id uuid not null references public.ticket_line(id) on delete restrict,
  line_type      public.line_type not null,
  base_amount    numeric(12,2) not null,                 -- = line_total; negative on reversal
  rate           numeric(5,2) not null check (rate between 0 and 100),
  amount         numeric(12,2) not null,                 -- round(base*rate/100,2); negative on reversal
  is_reversal    boolean not null default false,
  earned_at      timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  -- DB-guarantee the commission math (defense in depth; pay_ticket must match the
  -- §3 formula). Holds for reversals (base & amount both flip sign; round() is
  -- half-away-from-zero) and for zero-rate lines (amount 0).
  constraint commission_amount_chk check (amount = round(base_amount * rate / 100, 2))
);
alter table public.commission_entry enable row level security;

-- at most one earning and one reversal per line (idempotency + no double-count)
create unique index uq_commission_line_earning  on public.commission_entry(ticket_line_id) where not is_reversal;
create unique index uq_commission_line_reversal on public.commission_entry(ticket_line_id) where is_reversal;
create index idx_commission_staff_earned on public.commission_entry(staff_id, earned_at);
create index idx_commission_ticket       on public.commission_entry(ticket_id);
