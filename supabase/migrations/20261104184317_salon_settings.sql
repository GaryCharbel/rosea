-- M02 — salon_settings (singleton).
-- One row of salon-wide config (id is identity + CHECK (id = 1), so a second
-- row can never be inserted). tax_rate and loyalty_enabled are forward hooks for
-- later stages (fixed/false in Stage 1). RLS is enabled in Phase 2 (M-rls).
create table public.salon_settings (
  id              integer primary key generated always as identity check (id = 1),
  name            text not null default 'Rosea',
  currency        text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  timezone        text not null default 'UTC',
  address         text,
  tax_rate        numeric(5,2) not null default 0 check (tax_rate between 0 and 100), -- HOOK (Stage 3), fixed 0 now
  loyalty_enabled boolean not null default false,                                     -- HOOK (Stage 4)
  receipt_header  text,
  receipt_footer  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger trg_salon_settings_updated before update on public.salon_settings
  for each row execute function public.set_updated_at();

insert into public.salon_settings (name) values ('Rosea'); -- id = 1
