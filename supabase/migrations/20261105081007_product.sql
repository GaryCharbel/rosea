-- M08 — product (+ category-kind guard, reusing public.enforce_category_kind from M07).
-- commission_eligible gates whether a product line can earn commission (rate on staff).
-- Oversell is allowed: stock_quantity may go negative (NO >= 0 CHECK); negatives are
-- surfaced in reports. RLS enabled at creation (default-deny); policies in Phase 2.
create table public.product (
  id                  uuid primary key default gen_random_uuid(),
  category_id         uuid references public.category(id) on delete set null,
  name                text not null check (length(trim(name)) > 0),
  description         text,
  price               numeric(12,2) not null check (price >= 0),
  sku                 text unique,
  image_url           text,
  track_stock         boolean not null default false,
  stock_quantity      integer not null default 0,   -- may go negative; flagged in reports
  commission_eligible boolean not null default true,
  active              boolean not null default true,
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table public.product enable row level security;

create trigger trg_product_updated before update on public.product
  for each row execute function public.set_updated_at();

create index idx_product_active on public.product(category_id, sort_order) where active;

create trigger trg_product_category_kind
  before insert or update of category_id on public.product
  for each row execute function public.enforce_category_kind('product');
