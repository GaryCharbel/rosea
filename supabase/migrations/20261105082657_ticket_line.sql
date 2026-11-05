-- M11 — ticket_line (performer-per-line) + immutability guard.
-- line_total is GENERATED: round(unit_price*qty,2) - line_discount. Each line is
-- credited to performer_staff_id. commission_*_snapshot are written by pay_ticket.
-- RLS enabled at creation; policies in Phase 2.
create table public.ticket_line (
  id                       uuid primary key default gen_random_uuid(),
  ticket_id                uuid not null references public.ticket(id) on delete cascade,
  line_type                public.line_type not null,
  service_id               uuid references public.service(id) on delete restrict,
  product_id               uuid references public.product(id) on delete restrict,
  name_snapshot            text not null,
  unit_price               numeric(12,2) not null check (unit_price >= 0),
  qty                      numeric(10,3) not null default 1 check (qty > 0),
  line_discount            numeric(12,2) not null default 0 check (line_discount >= 0),
  line_total               numeric(12,2) generated always as (round(unit_price*qty,2) - line_discount) stored,
  performer_staff_id       uuid not null references public.staff(id) on delete restrict,
  commission_rate_snapshot numeric(5,2) check (commission_rate_snapshot between 0 and 100),
  commission_amount        numeric(12,2) check (commission_amount >= 0),
  created_at               timestamptz not null default now(),
  constraint ticket_line_discount_chk check (line_discount <= round(unit_price*qty,2)),
  constraint ticket_line_kind_chk check (
      (line_type='service' and service_id is not null and product_id is null)
   or (line_type='product' and product_id is not null and service_id is null)),
  constraint ticket_line_product_whole_qty check (line_type <> 'product' or qty = trunc(qty))
);

alter table public.ticket_line enable row level security;

create index idx_ticket_line_ticket    on public.ticket_line(ticket_id);
create index idx_ticket_line_performer on public.ticket_line(performer_staff_id);

-- Immutability: children of a non-open ticket are frozen (corrections = void + re-ring).
-- SECURITY INVOKER; `is distinct from 'open'` fails CLOSED if the ticket isn't resolvable.
create or replace function public.guard_child_only_when_open() returns trigger
  language plpgsql set search_path = '' as $$
declare v_status public.ticket_status;
begin
  select status into v_status from public.ticket where id = coalesce(new.ticket_id, old.ticket_id);
  if v_status is distinct from 'open' then
    raise exception 'Ticket is already closed; it cannot be modified. Void it and start a new ticket to make a correction.'
      using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end; $$;
create trigger trg_line_open before insert or update or delete on public.ticket_line
  for each row execute function public.guard_child_only_when_open();
