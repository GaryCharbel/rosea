-- M06 — category (service & product categories).
-- RLS enabled at creation (default-deny); policies land in Phase 2 / M-rls.
create table public.category (
  id         uuid primary key default gen_random_uuid(),
  kind       public.category_kind not null,
  name       text not null check (length(trim(name)) > 0),
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.category enable row level security;

create trigger trg_category_updated before update on public.category
  for each row execute function public.set_updated_at();

-- kind is immutable once created: changing it would orphan linked services/products
-- (the service/product kind-guard only fires on their own writes, not on a category
-- flipping kind underneath them).
create or replace function public.forbid_category_kind_change() returns trigger
  language plpgsql set search_path = '' as $$
begin
  if new.kind is distinct from old.kind then
    raise exception 'A category''s kind cannot be changed once created — create a new category instead.'
      using errcode = 'check_violation';
  end if;
  return new;
end; $$;
create trigger trg_category_kind_immutable before update of kind on public.category
  for each row execute function public.forbid_category_kind_change();

-- case-insensitive uniqueness within a kind ('Hair' and 'hair' collide)
create unique index uq_category_kind_name on public.category(kind, lower(name));

create index idx_category_kind on public.category(kind, sort_order) where active;
