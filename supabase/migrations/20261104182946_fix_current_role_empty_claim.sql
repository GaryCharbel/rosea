-- Fix: private.current_role() raised 'invalid input syntax for type json' when
-- request.jwt.claims is an empty string ('') — the ::jsonb cast ran before the
-- outer nullif, so an empty claim crashed instead of falling back to the profiles
-- read. M01 shipped the original and migrations are forward-only, so this is a
-- follow-up create-or-replace rather than an edit to M01.
--
-- current_role() still reads public.profiles (created in M05), so body validation
-- is disabled for the redefinition, exactly as M01 does.
set check_function_bodies = off;

create or replace function private.current_role() returns public.user_role
  language sql stable security definer set search_path = '' as $$
  -- inner nullif(...,'') guards the ::jsonb cast: both an absent (NULL) claim and
  -- an empty-string ('') claim become "no claim" and fall back to the profiles read.
  select coalesce(
    nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'user_role','')::public.user_role,
    (select p.role from public.profiles p where p.id = (select auth.uid())));
$$;

reset check_function_bodies;
