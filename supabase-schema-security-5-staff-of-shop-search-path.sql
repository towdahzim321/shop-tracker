-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 5: search_path hardening
-- for staff_of_shop and require_day_open
-- ============================================================================
-- Additive only. CREATE OR REPLACE is correct here, not DROP+CREATE - the
-- parameter list of both functions is unchanged (staff_of_shop(uuid, text),
-- require_day_open(text, date), verified live via pg_get_functiondef
-- immediately before writing this file). Only each function's own
-- SET search_path configuration is being added; nothing about the callable
-- signature changes, so the function-signature-change rule (DROP FUNCTION +
-- CREATE + NOTIFY pgrst) does not apply, and no schema-cache reload is
-- needed - PostgREST's function cache is keyed on name+argument types, not
-- on a function's internal search_path setting.
--
-- WHY THIS EXISTS
-- These two are the last staff-facing SECURITY DEFINER functions still
-- missing SET search_path - every idempotent staff RPC that calls them
-- (staff_sell_phone, staff_return_phone, staff_receive_stock,
-- staff_submit_eod, staff_open_day, staff_close_day) already got
-- `set search_path to 'public', 'pg_temp'` in supabase-schema-part6e/
-- part6f, but staff_of_shop and require_day_open themselves - the two
-- helper functions every one of those RPCs calls first - were never
-- covered by that pass (confirmed live: proconfig was empty on both before
-- this file).
--
-- IS THIS LIVE-EXPLOITABLE OR JUST DEFENCE-IN-DEPTH? CHECKED, NOT ASSUMED.
-- anon/authenticated cannot CREATE in public or extensions (nspacl on both
-- schemas shows `U` only for both roles, confirmed via has_schema_privilege
-- and raw pg_namespace.nspacl). But both roles DO hold database TEMP
-- privilege (has_database_privilege(role, current_database(), 'TEMP') =
-- true for both) - which lets them create session-scoped temp tables, and
-- Postgres searches the temp schema ahead of an unqualified relation name
-- unless the function's own search_path explicitly repositions it.
-- Proved live on STAGING (rolled back, no lasting change):
--   begin;
--   set local role anon;
--   create temp table staff (id uuid, shop_id text, name text, active boolean);
--   insert into staff values
--     ('00000000-0000-0000-0000-000000000000','harare',
--      'INJECTED-NAME-VIA-TEMP-TABLE',true);
--   select staff_of_shop('00000000-0000-0000-0000-000000000000'::uuid, 'harare');
--   rollback;
-- returned 'INJECTED-NAME-VIA-TEMP-TABLE' for a UUID that does not exist in
-- the real staff table - staff_of_shop should have raised "Staff member not
-- recognised for this shop." but the temp table shadowed the real one. Real
-- temp-table shadowing, not a theoretical concern. (Reach caveat: PostgREST/
-- supabase-js only exposes .rpc()/.from(), not arbitrary DDL, so there's no
-- confirmed path for an anon-key holder to issue CREATE TEMP TABLE through
-- the app today - but the privilege escalation is real at the database
-- layer, and becomes exploitable the instant any other SQL-execution path
-- to anon/authenticated exists.)
--
-- CRYPT()/GEN_SALT() CHECK (done live, immediately before writing this
-- file, not assumed)
-- Re-pulled both functions' current live bodies via pg_get_functiondef and
-- grepped for crypt(/gen_salt( - zero matches in either. Neither touches
-- pin_hash or calls anything in `extensions`. 'public', 'pg_temp' is the
-- complete, correct path for both - matching the six idempotent staff RPCs
-- (part6e/6f), not the 'public', 'extensions', 'pg_temp' pattern used for
-- the PIN functions (admin_set_staff_pin, admin_reset_staff_pin,
-- staff_login), which genuinely need `extensions` for crypt()/gen_salt().
--
-- WHAT CHANGED, PER FUNCTION
-- Nothing in either function's body - every statement, same order, same
-- text as currently live (verified above). The only addition is the
-- `set search_path to 'public', 'pg_temp'` clause on the function
-- declaration itself. After this file, every SECURITY DEFINER function in
-- the staff call chain - the six RPCs plus these two helpers they both
-- call - resolves unqualified names from a fixed, non-hijackable path
-- instead of whatever search_path the calling session happens to have.
-- ============================================================================

create or replace function staff_of_shop(p_staff_id uuid, p_shop_id text)
returns text
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_name text;
begin
  select name into v_name from staff where id = p_staff_id and shop_id = p_shop_id and active;
  if v_name is null then raise exception 'Staff member not recognised for this shop.'; end if;
  return v_name;
end; $$;

create or replace function require_day_open(p_shop_id text, p_local_date date)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_status text;
begin
  select status into v_status from business_days where shop_id = p_shop_id and date = p_local_date;
  if v_status is distinct from 'open' then
    raise exception 'Today''s business day is not open. Open it before adding entries.';
  end if;
end; $$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- Both rows should show search_path=public,pg_temp
-- ============================================================================
select p.proname, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_of_shop','require_day_open')
order by p.proname;

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's CRLF-on-Windows
-- note, pipe through stdin rather than passing a filepath to -f:
--   cat supabase-schema-security-5-staff-of-shop-search-path.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-5-staff-of-shop-search-path.sql | psql "$DATABASE_URL" -f -
-- After staging: re-run the exploit test above against the patched
-- staff_of_shop and confirm it now raises "Staff member not recognised for
-- this shop." instead of returning the injected name.
-- ============================================================================
