-- Seed: auth users for LOCAL dev only (owner + one staff). Password: rosea1234
-- These are demo credentials for `supabase db reset` against the local stack — never
-- real secrets, and NOT used on a hosted project (there, create the owner in the
-- dashboard). Ordered before 10_demo.sql so the staff link points at a seeded staff.
--
-- session_replication_role=replica bypasses the handle_new_user + role-change-guard
-- triggers (and the forward FK to staff, created in 10_demo) so we can set roles
-- directly; CHECK/UNIQUE constraints still apply.
set session_replication_role = replica;

insert into auth.users
  (instance_id, id, aud, role, email, encrypted_password,
   email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-00000000006f',
   'authenticated', 'authenticated', 'owner@rosea.local',
   extensions.crypt('rosea1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Owner"}'),
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-000000000057',
   'authenticated', 'authenticated', 'lea@rosea.local',
   extensions.crypt('rosea1234', extensions.gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Lea"}')
on conflict (id) do nothing;

-- profiles: owner (no staff link) + staff Lea linked to the seeded staff row (10_demo).
insert into public.profiles (id, role, staff_id, full_name) values
  ('0b000000-0000-0000-0000-00000000006f', 'owner', null, 'Owner'),
  ('0b000000-0000-0000-0000-000000000057', 'staff',
   '57000000-0000-0000-0000-0000000000a1', 'Lea')
on conflict (id) do nothing;

set session_replication_role = origin;
