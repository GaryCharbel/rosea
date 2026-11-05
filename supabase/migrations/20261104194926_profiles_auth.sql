-- M05 — profiles + auth bridge.
-- One profiles row per auth.users (auto-created on signup, default 'client').
-- profiles.role drives authorization; staff_id/client_id bridge to the domain rows.
-- Role is mirrored into the JWT via the custom access token hook; private.current_role()
-- falls back to a profiles read when the claim is absent/stale.
-- RLS is enabled at creation (default-deny); policies land in Phase 2. NOT forced, so
-- the SECURITY DEFINER helpers (owned by a bypassrls role) can read/write profiles.

-- ── table ─────────────────────────────────────────────────────────────────────
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.user_role not null default 'client',
  staff_id   uuid unique references public.staff(id)  on delete set null,
  client_id  uuid unique references public.client(id) on delete set null,
  full_name  text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_role_link_chk check (
        (role='owner'  and staff_id is null and client_id is null)
     or (role='staff'  and staff_id is not null and client_id is null)
     or (role='client' and staff_id is null))
);
-- Note: staff/client use soft-delete (active). Hard-deleting a row linked to a
-- role='staff' profile would trip role_link_chk via the FK set-null, so demote the
-- profile first (set_user_role) before any hard delete.

-- ── RLS: enabled at creation (default-deny; NOT forced — definer helpers bypass) ──
alter table public.profiles enable row level security;

-- ── updated_at trigger ─────────────────────────────────────────────────────────
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- ── auto-create a profile on signup (default 'client') ──────────────────────────
create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── anti-escalation: only an owner may change role/links ────────────────────────
create or replace function public.guard_profile_role_change() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  if (new.role, new.staff_id, new.client_id) is distinct from (old.role, old.staff_id, old.client_id)
     and private.current_role() is distinct from 'owner' then  -- is-distinct: a NULL role is treated as not-owner (blocked), never a bypass
    raise exception 'Only an owner can change a user''s role or staff/client link. Ask the owner to update this account.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end; $$;
create trigger trg_profiles_guard_role before update on public.profiles
  for each row execute function public.guard_profile_role_change();

-- ── owner-only role assignment RPC ──────────────────────────────────────────────
create or replace function public.set_user_role(
  p_user_id uuid, p_role public.user_role, p_staff_id uuid default null, p_client_id uuid default null)
  returns void language plpgsql security definer set search_path = '' as $$
begin
  if private.current_role() is distinct from 'owner' then  -- is-distinct: NULL role is rejected, never a bypass
    raise exception 'Only an owner can assign roles.' using errcode = 'insufficient_privilege'; end if;
  update public.profiles set role=p_role, staff_id=p_staff_id, client_id=p_client_id where id=p_user_id;
  if not found then
    raise exception 'No profile for user %. The user must sign in once before being assigned a role.', p_user_id
      using errcode = 'no_data_found'; end if;
end; $$;
revoke execute on function public.set_user_role(uuid, public.user_role, uuid, uuid) from public, anon;
grant  execute on function public.set_user_role(uuid, public.user_role, uuid, uuid) to authenticated;

-- ── JWT custom claim (role + staff_id) — registered in Dashboard → Auth → Hooks ──
create or replace function public.custom_access_token_hook(event jsonb) returns jsonb
  language plpgsql stable security definer set search_path = '' as $$
declare claims jsonb := event->'claims'; r public.user_role; sid uuid;
begin
  select p.role, p.staff_id into r, sid from public.profiles p where p.id = (event->>'user_id')::uuid;
  if r is not null then
    claims := jsonb_set(claims, '{user_role}', to_jsonb(r::text));
    claims := jsonb_set(claims, '{staff_id}',  coalesce(to_jsonb(sid::text),'null'::jsonb));
  end if;
  return jsonb_set(event, '{claims}', claims);
end; $$;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on table public.profiles to supabase_auth_admin;
