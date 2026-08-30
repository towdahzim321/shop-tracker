-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 10: session-gate the two
-- staff read RPCs
-- ============================================================================
-- Closes a finding from the security audit: staff_recent_daily_logs and
-- staff_today_expenses are SECURITY DEFINER, granted to anon, and take only
-- p_shop_id - unlike the seven staff WRITE RPCs, neither ever calls
-- require_staff_session. Proven live against staging in the audit: both
-- returned full data (60 days of EOD cash/count logs with staff attribution
-- and resubmission history; itemized expenses with staff_id) to a caller
-- holding nothing but the public anon key - no login, no session, ever.
--
-- SIGNATURE CHANGE, NOT CREATE OR REPLACE. Each function gains two new
-- trailing parameters (p_staff_id uuid default null, p_session_token uuid
-- default null) - an explicit DROP FUNCTION on the exact old signature,
-- then CREATE, for both, then a single NOTIFY pgrst at the end (matches
-- security-8's precedent of batching several signature changes into one
-- file with one trailing reload). The defaults are what let the call still
-- resolve for whatever client is live during the deploy gap - not a
-- substitute for the drop itself, and not a lenient fallback: the body
-- calls require_staff_session() unconditionally, so a caller sending no
-- token gets a clean "Your session has expired. Please sign in again."
-- business-rule error, not a broken/ambiguous RPC call. Client cutover
-- (index.html sending p_staff_id/p_session_token on these two calls) ships
-- in the same commit as this file, so the gap is only the time between
-- applying this to production and deploy.sh finishing.
--
-- Fresh live bodies of both functions were pulled via pg_get_functiondef
-- immediately before writing this file - every line below outside the two
-- new parameters and the require_staff_session call is byte-identical to
-- what was live.
--
-- No explicit GRANT: Supabase's default privileges grant EXECUTE to
-- anon/authenticated on any new function in public automatically (the same
-- mechanism every other function in this schema already relies on, see
-- AGENTS.md's Grants section) - the verification query below checks this
-- held rather than assuming it.
-- ============================================================================

drop function if exists public.staff_recent_daily_logs(text);
create function public.staff_recent_daily_logs(p_shop_id text, p_staff_id uuid default null, p_session_token uuid default null)
returns setof daily_logs
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  perform require_staff_session(p_session_token, p_staff_id, p_shop_id);
  return query
    select * from daily_logs
    where shop_id = p_shop_id
      and date >= (current_date - 60)
    order by date desc;
end; $$;

drop function if exists public.staff_today_expenses(text, date);
create function public.staff_today_expenses(p_shop_id text, p_local_date date, p_staff_id uuid default null, p_session_token uuid default null)
returns setof expenses
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  perform require_staff_session(p_session_token, p_staff_id, p_shop_id);
  return query
    select * from expenses
    where shop_id = p_shop_id and date = p_local_date
    order by created_at;
end; $$;

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
  pg_get_function_result(p.oid) as returns, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_recent_daily_logs', 'staff_today_expenses');
-- Expect: both now show the two new params, search_path unchanged.

select routine_name, grantee, privilege_type
from information_schema.role_routine_grants
where specific_schema = 'public'
  and routine_name in ('staff_recent_daily_logs', 'staff_today_expenses')
  and grantee in ('anon', 'authenticated');
-- Expect: EXECUTE for both roles on both functions (default privileges
-- reapplied after the drop+create, same as every other function here).

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's CRLF note, pipe
-- through stdin:
--   cat supabase-schema-security-10-gate-staff-read-rpcs.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-10-gate-staff-read-rpcs.sql | psql "$DATABASE_URL" -f -
-- Verify against staging (re-run the audit's exploit: call both RPCs with
-- anon key only, no session - expect rejection; then a real logged-in call
-- - expect success) BEFORE applying to production. Only the read-only
-- verification queries above run against production - no exploit attempt,
-- ever, on $DATABASE_URL.
-- ============================================================================
