-- pgTAP — M05 profiles + auth bridge (structural; full behavioral runs in the local sandbox).
-- Behavioral profile inserts need a real auth.users row (FK), which isn't safe to
-- fabricate in CI, so those are exercised in the sandbox. Here we assert structure
-- plus the access-token hook's no-profile path (callable without any row).
begin;
select plan(11);

select has_table('public', 'profiles', 'profiles table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.profiles'::regclass), 'RLS is enabled on profiles');
select has_trigger('public', 'profiles', 'trg_profiles_updated', 'updated_at trigger present');
select has_trigger('public', 'profiles', 'trg_profiles_guard_role', 'role-change guard trigger present');
select has_trigger('auth', 'users', 'on_auth_user_created', 'signup trigger present on auth.users');

select has_function('public', 'handle_new_user', 'handle_new_user() exists');
select has_function('public', 'guard_profile_role_change', 'guard_profile_role_change() exists');
select has_function('public', 'set_user_role', 'set_user_role() exists');
select has_function('public', 'custom_access_token_hook', 'custom_access_token_hook() exists');

select ok(
  (select count(*) from pg_constraint where conname = 'profiles_role_link_chk' and conrelid = 'public.profiles'::regclass) = 1,
  'profiles_role_link_chk constraint exists');

-- hook: when the user has no profile, claims pass through unchanged
select is(
  public.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-000000000000","claims":{"sub":"x"}}'::jsonb),
  '{"user_id":"00000000-0000-0000-0000-000000000000","claims":{"sub":"x"}}'::jsonb,
  'access-token hook leaves claims unchanged when the user has no profile');

select * from finish();
rollback;
