-- M07 — service (+ shared category-kind guard).
-- bookable_online / duration_minutes are Stage-2 hooks (present, unused in Stage 1).
-- RLS enabled at creation (default-deny); policies land in Phase 2 / M-rls.
create table public.service (
  id               uuid primary key default gen_random_uuid(),
  category_id      uuid references public.category(id) on delete set null,
  name             text not null check (length(trim(name)) > 0),
  description      text,
  price            numeric(12,2) not null check (price >= 0),
  duration_minutes integer not null default 30 check (duration_minutes > 0),
  image_url        text,
  active           boolean not null default true,
  bookable_online  boolean not null default false,  -- HOOK Stage 2
  sort_order       integer not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.service enable row level security;

create trigger trg_service_updated before update on public.service
  for each row execute function public.set_updated_at();

create index idx_service_active on public.service(category_id, sort_order) where active;

-- Shared category-kind guard: a service/product line may only reference a category
-- of the matching kind. SECURITY INVOKER + `is distinct from` so it fails CLOSED
-- (blocks) rather than open if the category isn't visible/resolvable. The expected
-- kind is passed as a trigger argument so one function serves both tables.
create or replace function public.enforce_category_kind() returns trigger
  language plpgsql set search_path = '' as $$
begin
  if new.category_id is not null
     and (select kind from public.category where id = new.category_id)
         is distinct from tg_argv[0]::public.category_kind then
    raise exception 'A % cannot use that category — assign a % category, or leave it empty.',
      tg_table_name, tg_argv[0]
      using errcode = 'check_violation';
  end if;
  return new;
end; $$;

create trigger trg_service_category_kind
  before insert or update of category_id on public.service
  for each row execute function public.enforce_category_kind('service');
