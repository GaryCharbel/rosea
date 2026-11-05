-- M12–M13 — payment + tip (money tables).
-- RPC-write-only: only pay_ticket/void_ticket (SECURITY DEFINER) write these; direct
-- authenticated writes are blocked by RLS (default-deny now; using(false)+REVOKE in
-- Phase 2). amount is the amount APPLIED to the ticket, negative on a void reversal.
--
-- NOTE: unlike ticket_line, payment/tip deliberately do NOT carry the
-- guard_child_only_when_open trigger. pay_ticket writes them while the ticket is still
-- 'open'; void_ticket writes the negative reversal rows while it is 'paid'. The guard
-- (is distinct from 'open') would block the void path, and it is redundant here anyway
-- since these tables are RPC-write-only. (Spec §5.9 showed the guard on payment/tip,
-- which contradicts void_ticket in §7.2 — resolved by omitting it.)
create table public.payment (
  id         uuid primary key default gen_random_uuid(),
  ticket_id  uuid not null references public.ticket(id) on delete cascade,
  method     public.payment_method not null,
  amount     numeric(12,2) not null check (amount <> 0),  -- applied amount; negative on void reversal
  reference  text,
  taken_by   uuid not null references public.staff(id) on delete restrict,
  client_tx  uuid not null,
  created_at timestamptz not null default now()
);
alter table public.payment enable row level security;
create index idx_payment_ticket      on public.payment(ticket_id);
create index idx_payment_method_date on public.payment(method, created_at); -- cash-up

create table public.tip (
  id         uuid primary key default gen_random_uuid(),
  ticket_id  uuid not null references public.ticket(id) on delete cascade,
  staff_id   uuid not null references public.staff(id) on delete restrict,
  amount     numeric(12,2) not null check (amount <> 0),  -- negative on void reversal
  method     public.payment_method,                       -- how the tip was tendered (cash-up)
  client_tx  uuid not null,
  created_at timestamptz not null default now()
);
alter table public.tip enable row level security;
create index idx_tip_ticket     on public.tip(ticket_id);
create index idx_tip_staff_date on public.tip(staff_id, created_at);
