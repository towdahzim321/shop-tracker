-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 6: search_path hardening
-- for is_admin and require_admin
-- ============================================================================
-- Additive only. CREATE OR REPLACE is correct here, not DROP+CREATE - both
-- are zero-argument functions and the parameter list (none) is unchanged.
-- Only each function's own SET search_path configuration is being added;
-- nothing about the callable signature changes, so the function-signature-
-- change rule (DROP FUNCTION + CREATE + NOTIFY pgrst) does not apply, and no
-- schema-cache reload is needed.
--
-- WHY THIS EXISTS
-- is_admin() and require_admin() were the last two SECURITY DEFINER
-- functions in the admin trust chain missing SET search_path (confirmed via
-- a full sweep last session: 21 functions total - these two plus all 19
-- admin_* RPCs - had proconfig null/no search_path entry). Proved this is
-- live-exploitable, not just defence-in-depth, on STAGING (rolled back):
--   begin;
--   set local role authenticated;
--   set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
--   select is_admin();                                        -- f
--   create temp table admins (user_id uuid, username text);
--   insert into admins values
--     ('11111111-1111-1111-1111-111111111111', 'shadow-admin');
--   select is_admin();                                         -- t
--   rollback;
-- Any authenticated (non-admin) Supabase Auth user could self-escalate past
-- is_admin() via a session temp table shadowing the unqualified `admins`
-- reference - the same class of bug just fixed for staff_of_shop/
-- require_day_open in security-5, except this one gates all 19 admin_*
-- RPCs plus the admin-only RLS policies on business_days/daily_logs/
-- expenses/ledger/model_audit/phones/settings/shop_resets/shops/staff.
-- (Tested as anon too: auth.uid() came back NULL - real anon-key JWTs carry
-- no `sub` claim - so `where user_id = auth.uid()` can never match
-- regardless of temp-table contents. Not exploitable via anon directly, but
-- incidental NULL-comparison behaviour, not real access control.)
--
-- REACHABILITY: CHECKED, NOT ASSUMED. Production Auth self-signup is
-- enabled - confirmed via GoTrue's public /auth/v1/settings endpoint
-- (read-only, no table touched):
--   GET https://fyizncdfxjfmenudcfds.supabase.co/auth/v1/settings
--   {"external":{...,"email":true,...},"disable_signup":false,
--    "mailer_autoconfirm":false,...}
-- disable_signup=false + external.email=true means anyone holding only the
-- published anon key can create a real Supabase Auth account with no
-- existing account required. mailer_autoconfirm=false means the new
-- account needs email confirmation before login, but the attacker chooses
-- and controls the signup email address, so they receive and can click
-- that confirmation link themselves - an extra step, not a real blocker.
-- This is exploitable by any stranger holding the anon key, not only by an
-- existing account holder.
--
-- SCOPE: read all 19 admin_* function bodies before writing this file.
-- Every one of them calls `perform require_admin();` (or `if not is_admin()
-- then raise exception` for admin_set_staff_pin) as its literal first
-- statement, before any unqualified table reference. So hardening just
-- these two closes the escalation vector for all 19 RPCs and every RLS
-- policy that calls is_admin() - none of the 19 need their own guard for
-- *this* fix to be complete. Not fixed here, and explicitly out of scope
-- for this file: most of the 19 still lack their own SET search_path for
-- their post-gate business logic (the update/insert statements after the
-- admin check passes) - a different, lower-severity concern since it would
-- require an already-legitimate admin session to matter, not a privilege
-- escalation.
--
-- WHAT CHANGED, PER FUNCTION
-- Nothing in either function's body - every statement, same order, same
-- text as currently live (verified via pg_get_functiondef immediately
-- before writing this file). The only addition is the
-- `set search_path to 'public', 'pg_temp'` clause. is_admin()'s only other
-- reference, auth.uid(), is already schema-qualified so search_path doesn't
-- affect it - only the unqualified `admins` table lookup was the hijack
-- surface. Neither function calls crypt()/gen_salt(), so 'public',
-- 'pg_temp' is the complete, correct path (same reasoning as security-5).
-- ============================================================================

create or replace function is_admin()
returns boolean
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select exists(select 1 from admins where user_id = auth.uid());
$$;

create or replace function require_admin()
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not is_admin() then raise exception 'Admin only.'; end if;
end; $$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- Both rows should show search_path=public,pg_temp
-- ============================================================================
select p.proname, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('is_admin','require_admin')
order by p.proname;

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's corrected CRLF
-- note, pipe through stdin rather than passing a filepath to -f (a single,
-- non-doubled \r\n per line is expected and harmless either way - the check
-- that matters is zero doubled \r\r):
--   cat supabase-schema-security-6-is-admin-search-path.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-6-is-admin-search-path.sql | psql "$DATABASE_URL" -f -
--
-- Before production: re-run the exploit test above against patched staging
-- and confirm is_admin() now stays f. Also confirm the legitimate admin
-- path still works - staging's real `admins` table is empty, so simulate
-- one inside a rolled-back transaction:
--   begin;
--   insert into admins values ('<fake uuid>', 'test-admin');
--   set local role authenticated;
--   set local request.jwt.claim.sub = '<that fake uuid>';
--   select require_admin();          -- must not raise
--   select * from phones limit 1;    -- must succeed (phones_admin_all RLS)
--   rollback;
-- ============================================================================
