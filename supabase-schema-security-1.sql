-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 1: additive-only
-- ============================================================================
-- Run this any time. It is safe to run before, during, or after deploying
-- the accompanying index.html - every statement in this file is additive
-- (new view, new functions, or a same-signature CREATE OR REPLACE with
-- unchanged logic). Nothing that already exists is dropped or narrowed.
--
-- CONFIRM: after this file alone runs, the OLD deployed app (the version
-- live before this change) keeps working completely untouched. It still
-- reads `staff` directly (staff_read_names, unchanged, still in place) and
-- `daily_logs` directly for everyone (daily_logs_anon_read, unchanged,
-- still in place). staff_login/admin_set_staff_pin/admin_reset_staff_pin
-- behave identically - their bodies are byte-for-byte what was live before,
-- just with an explicit search_path added. staff_public and
-- staff_recent_daily_logs are new objects the old app never calls, so their
-- existence is inert to it. Nothing in this file can break the currently-
-- live site.
--
-- WHY THIS EXISTS
-- Two separate {public}/SELECT/qual=true policies, found in the same
-- session: staff_read_names on staff (exposed pin_hash to anyone with the
-- anon key) and daily_logs_anon_read on daily_logs (exposed every shop's
-- cash figures, forever, to anyone with the anon key). Both get the same
-- fix shape: stop the wide-open table read, give the legitimate
-- unauthenticated need a narrow, purpose-built door instead - a view for
-- staff names, an RPC for daily logs - and remove the wide-open policy in
-- a SEPARATE file (security-2.sql) only once the app depending on the new
-- doors is confirmed deployed.
--
-- SEQUENCING — WHY staff_recent_daily_logs LIVES HERE, NOT IN FILE 2
-- The run order has to be: run this file -> deploy the app -> run file 2.
-- The deployed app calls staff_recent_daily_logs the moment it's live.  If
-- that function were only created in file 2 (as first drafted), every
-- staff device would get "function does not exist" for the entire gap
-- between deploying the app and running file 2 - a real outage, not a
-- theoretical one. Creating the function here, before the app that calls
-- it ever ships, closes that gap. It works immediately even though
-- daily_logs_anon_read hasn't been dropped yet, because it's SECURITY
-- DEFINER and reads via its own privileges, not the caller's - the
-- underlying policy being wide open a bit longer doesn't affect it either
-- way.
--
-- REALITY CHECK — READ THIS BEFORE RUNNING
-- The original plan for the staff half of this file assumed a plain `pin`
-- column still existed alongside a new `pin_hash`, needing a backfill and a
-- transitional staff_login that accepts either. The actual live schema,
-- confirmed via pg_get_functiondef and information_schema.columns before
-- writing this file: staff.pin_hash already exists and is NOT NULL, there
-- is no `pin` column at all, and staff_login/admin_set_staff_pin/
-- admin_reset_staff_pin already hash exclusively via crypt()/gen_salt('bf').
-- There was never a plaintext PIN in this database to migrate off or be
-- backward-compatible with. So: no ALTER TABLE ADD COLUMN, no backfill
-- UPDATE, no dual-mode login - the three functions below are re-created
-- with search_path pinned and are otherwise identical to what's live.
--
-- WHAT ONLY STAFF ACTUALLY NEEDED FROM daily_logs, AND WHAT THIS GIVES THEM
-- Grepping every staff-reachable screen that reads dailyLogs turns up: "has
-- today's end-of-day already been submitted" (staff menu), "pre-fill if
-- resubmitting today" (End of day screen), and "show the counted/cash row
-- on a printed stock sheet" (which staff can view for a past date they
-- pick, not only today). Nothing staff-facing needs another shop's data or
-- the entire all-time history. staff_recent_daily_logs(p_shop_id) below
-- returns just that one shop's logs from the last 60 days - covers today's
-- check with room to spare, and covers the stock sheet for any recent
-- date. A staff-facing stock sheet printed for a date OLDER than 60 days
-- will show "not submitted" for the counted/cash row even if a log exists
-- further back - a real but minor regression, and the tradeoff the owner
-- explicitly signed off on ("recent logs is fine for now"). Widen the
-- window later if that turns out to matter in practice.
-- This function is still callable by anyone with the anon key, same as
-- staff_login and every other staff_* RPC - staff are never authenticated
-- Supabase Auth users, so "admin-only" isn't an option here. The win is
-- narrowing from "every shop, forever" to "one named shop, 60 days," not
-- eliminating anon access entirely.
--
-- THE ADMIN PATH NEEDS NO NEW POLICY HERE
-- refreshShopData reads `daily_logs` directly for admin sessions
-- (unconditionally, unchanged) - checked in index.html before writing this
-- file, not assumed. daily_logs_admin_all ({public}, ALL, is_admin()) was
-- already in place before any of this work started and already covers
-- that read. It is independent of daily_logs_anon_read and isn't touched
-- by dropping it in file 2, so nothing needs to be added here for admin.
--
-- WHAT THIS ADDS
--   pgcrypto                — ensured present (no-op in practice; it must
--                              already be installed for the existing
--                              functions to work at all).
--   staff_public             — new view: id, name, shop_id, active only.
--                              No pin_hash. security_invoker = false so it
--                              reads with the view owner's rights and
--                              bypasses RLS on the base table - the same
--                              pattern already in production for
--                              phones_staff_view and ledger_staff_view.
--   staff_recent_daily_logs  — new SECURITY DEFINER function: one shop's
--                              daily_logs from the last 60 days. See above.
--   staff_login, admin_set_staff_pin, admin_reset_staff_pin — re-created
--                              with an explicit search_path added. Bodies
--                              are otherwise byte-for-byte what
--                              pg_get_functiondef returned for each before
--                              this file was written.
--
-- WHAT THIS FILE DOES NOT TOUCH
--   staff_read_names, daily_logs_anon_read - both still in place after this
--   file. Dropping them is the entire content of security-2.sql, and that
--   file must not run until the app below is deployed and confirmed
--   working. No DROP of any policy or column happens anywhere in this file.
--   The shops table shape (Phase 3) - unrelated, not touched here.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- Column-filtered view: exactly what the staff picker and ensureStaffNames
-- need (id, name, shop_id, active), never pin_hash. security_invoker=false
-- (the default, stated explicitly here) means it runs as its owner and
-- bypasses RLS on the base table, mirroring phones_staff_view/
-- ledger_staff_view already in production.
create or replace view staff_public
with (security_invoker = false)
as
select id, name, shop_id, active from staff;

grant select on staff_public to anon, authenticated;

-- One shop's daily_logs, last 60 days. See "WHAT ONLY STAFF ACTUALLY
-- NEEDED" above for why 60 days and why this is still anon-callable.
create or replace function staff_recent_daily_logs(p_shop_id text)
returns setof daily_logs
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  return query
    select * from daily_logs
    where shop_id = p_shop_id
      and date >= (current_date - 60)
    order by date desc;
end; $function$;

-- ---- The three functions below: logic unchanged, search_path pinned -------
-- Each body is copied verbatim from pg_get_functiondef() output taken
-- immediately before writing this file. search_path is set explicitly so
-- crypt()/gen_salt() and the bare `staff` reference always resolve from
-- known schemas, regardless of what search_path the calling session has -
-- the standard hardening for any SECURITY DEFINER function.

create or replace function public.staff_login(p_staff_id uuid, p_pin text)
returns table(id uuid, name text, shop_id text)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  return query
    select s.id, s.name, s.shop_id from staff s
    where s.id = p_staff_id and s.active
      and s.pin_hash = crypt(p_pin, s.pin_hash);
end; $function$;

create or replace function public.admin_set_staff_pin(p_shop_id text, p_name text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  insert into staff (shop_id, name, pin_hash)
    values (p_shop_id, p_name, crypt(p_pin, gen_salt('bf')))
    returning id into v_id;
  return v_id;
end; $function$;

create or replace function public.admin_reset_staff_pin(p_staff_id uuid, p_new_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
begin
  perform require_admin();
  update staff set pin_hash=crypt(p_new_pin, gen_salt('bf')), active=true where id=p_staff_id;
end; $function$;

-- ============================================================================
-- Done. Next: deploy the accompanying index.html change (staff picker and
-- ensureStaffNames read staff_public; refreshShopData reads daily_logs
-- through staff_recent_daily_logs for non-admin sessions). Once that's live
-- and confirmed working - a staff device can sign in and the staff menu
-- correctly shows today's status - run supabase-schema-security-2.sql to
-- close off staff_read_names and daily_logs_anon_read.
-- ============================================================================
