-- pgTAP sanity test. Run with: npx supabase test db
-- Phase 1 expands this to assert the private.* helpers and enums exist.
begin;
select plan(1);
select has_schema('public', 'public schema exists');
select * from finish();
rollback;
