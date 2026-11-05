-- M09–M10 — ticket.
-- Incremental lifecycle: staff INSERT an open ticket, then add lines; pay_ticket
-- (Phase 3) writes money + flips status last. paid_tx/void_tx make pay/void idempotent.
-- appointment_id is a Stage-2 hook, pinned null in Stage 1. RLS enabled at creation.
create table public.ticket (
  id             uuid primary key default gen_random_uuid(),
  ticket_no      bigint generated always as identity,          -- human receipt #, may gap
  status         public.ticket_status not null default 'open',
  opened_by      uuid not null references public.staff(id) on delete restrict,
  created_by     uuid not null default auth.uid() references public.profiles(id), -- for ownership RLS
  client_id      uuid references public.client(id) on delete set null,
  appointment_id uuid,                                         -- HOOK Stage 2, pinned null
  opened_at      timestamptz not null default now(),
  closed_at      timestamptz,
  subtotal       numeric(12,2) not null default 0 check (subtotal >= 0),
  discount_total numeric(12,2) not null default 0 check (discount_total >= 0),
  total          numeric(12,2) not null default 0 check (total >= 0),
  paid_tx        uuid unique,                                  -- idempotency: client_tx that paid it
  void_tx        uuid unique,                                  -- idempotency: client_tx that voided it
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint ticket_closed_at_chk check ((status='open' and closed_at is null) or (status<>'open' and closed_at is not null)),
  constraint ticket_appointment_stage1 check (appointment_id is null)
);

alter table public.ticket enable row level security;

create trigger trg_ticket_updated before update on public.ticket
  for each row execute function public.set_updated_at();

create index idx_ticket_status_opened on public.ticket(status, opened_at desc);
create index idx_ticket_client        on public.ticket(client_id);
create index idx_ticket_closed_at     on public.ticket(closed_at desc) where status='paid';
