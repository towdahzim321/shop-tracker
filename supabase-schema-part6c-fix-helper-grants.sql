-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6c: fix the idempotency helper grants
-- Phase 4a (plumbing) — hotfix
-- ============================================================================
-- THE TRAP
-- Part 6's revoke only removed EXECUTE from the PUBLIC pseudo-role:
--   revoke execute on function idempotency_begin(uuid, text) from public;
-- Supabase's default privileges grant EXECUTE on new public-schema functions
-- DIRECTLY to anon and authenticated, not by way of PUBLIC. Revoking from
-- PUBLIC removed a grant that was never the one actually giving access - the
-- direct anon/authenticated grants were untouched, and the verification
-- query in part 6 (correctly written - has_function_privilege checks the
-- real effective privilege, not just a PUBLIC row) would have shown that
-- immediately, had Supabase's SQL editor not only displayed the last
-- statement's result. Confirmed by re-running the check on its own:
-- anon_can_execute = true for both helpers.
--
-- WHAT THIS DOES
-- Revokes EXECUTE from all three roles this time - public, anon, and
-- authenticated - the actual full set that can hold a grant on a
-- public-schema function under Supabase's defaults.
-- ============================================================================

revoke execute on function public.idempotency_begin(uuid, text) from public, anon, authenticated;
revoke execute on function public.idempotency_finish(uuid, jsonb) from public, anon, authenticated;

-- VERIFY (one statement, one result set - every row must read false)
select 'idempotency_begin' as fn, 'anon' as role, has_function_privilege('anon', 'idempotency_begin(uuid,text)', 'EXECUTE') as can_execute
union all
select 'idempotency_begin', 'authenticated', has_function_privilege('authenticated', 'idempotency_begin(uuid,text)', 'EXECUTE')
union all
select 'idempotency_finish', 'anon', has_function_privilege('anon', 'idempotency_finish(uuid,jsonb)', 'EXECUTE')
union all
select 'idempotency_finish', 'authenticated', has_function_privilege('authenticated', 'idempotency_finish(uuid,jsonb)', 'EXECUTE');
