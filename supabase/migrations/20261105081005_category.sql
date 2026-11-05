-- M06 — category (service & product categories).
-- RLS enabled at creation (default-deny); policies land in Phase 2 / M-rls.
create table public.category (
  id         uuid primary key default gen_random_uuid(),
  kind       public.category_kind not null,
  name       text not null check (length(trim(name)) > 0),
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (kind, name)
);

alter table public.category enable row level security;

create trigger trg_category_updated before update on public.category
  for each row execute function public.set_updated_at();

create index idx_category_kind on public.category(kind, sort_order) where active;
