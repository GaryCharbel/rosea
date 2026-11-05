-- M15 — stock_movement (ledger of product stock changes).
-- qty_delta is negative for a sale, positive for restock/void_restore. RPC-write-only
-- (RLS default-deny now; using(false)+REVOKE in Phase 2). No open-guard (void_restore
-- is written while the ticket is already paid/void).
create table public.stock_movement (
  id         uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.product(id) on delete restrict,
  reason     public.stock_reason not null,
  qty_delta  integer not null check (qty_delta <> 0),  -- negative for a sale
  ticket_id  uuid references public.ticket(id) on delete set null,
  note       text,
  created_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.stock_movement enable row level security;
create index idx_stock_movement_product on public.stock_movement(product_id, created_at);
