-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 2: close off staff + cash
-- ============================================================================
-- ██████████████████████████████████████████████████████████████████████████
-- █  DO NOT RUN THIS UNTIL THE APP IS DEPLOYED WITH THE index.html CHANGE   █
-- █  DELIVERED ALONGSIDE THIS FILE (staff picker + ensureStaffNames reading █
-- █  staff_public; refreshShopData reading daily_logs through the new      █
-- █  staff_recent_daily_logs RPC for non-admin sessions).                  █
-- █                                                                          █
-- █  Running this file first breaks two things immediately:                █
-- █   - the staff picker's only way to list names today is a direct,       █
-- █     unauthenticated read of the staff table; this file removes the     █
-- █     policy that allows that.                                           █
-- █   - the staff menu's "already submitted today" check and the End of    █
-- █     day screen's pre-fill are a direct, unauthenticated read of        █
-- █     daily_logs; this file removes that policy too.                     █
-- █  Until the new index.html is the one staff are actually using, both    █
-- █  reads have nowhere else to go.                                        █
-- ██████████████████████████████████████████████████████████████████████████
--
-- Run this AFTER supabase-schema-security-1.sql, and only once the deployed
-- Netlify site is serving the updated index.html and that's been confirmed
-- working - a staff member can open the app, see their name in the picker,
-- sign in, and the staff menu correctly shows whether today's business day
-- and end-of-day have already been done.
--
-- WHY THIS EXISTS
-- Two separate {public}/SELECT/qual=true policies, found in the same pass:
--   staff_read_names   on staff       - let anyone with the anon key read
--                                        pin_hash for every staff member.
--   daily_logs_anon_read on daily_logs - let anyone with the anon key read
--                                        every shop's cash figures, forever,
--                                        including cash amounts nobody but
--                                        the owner and that shop's staff
--                                        should ever see. Found while
--                                        auditing every other {public}/
--                                        qual=true policy per the owner's
--                                        request - a better catch than the
--                                        one that started this pair of
--                                        files, and folded into the same fix
--                                        rather than left for later.
-- Both are RLS policies with no column-level narrowing, so in both cases the
-- fix is the same shape: stop granting the anon role a wide-open table read,
-- and give whatever legitimate unauthenticated need existed a narrow,
-- purpose-built door instead (a view for staff, an RPC for daily_logs).
--
-- REALITY CHECK — READ THIS BEFORE RUNNING
-- The original plan for the staff half of this file included rewriting
-- staff_login "hash-only, no plain-pin fallback" and dropping a plain `pin`
-- column. Neither applies: staff_login has never had a plain-pin fallback
-- (see security-1.sql's own reality check - there was never a plaintext PIN
-- in this database), and there is no `pin` column to drop - only pin_hash
-- exists, and it's already NOT NULL. The DROP COLUMN statement below is kept
-- anyway, written as `drop column if exists`, purely as a safe no-op /
-- belt-and-suspenders statement: it does nothing today, and only matters if
-- a `pin` column is ever reintroduced by mistake later.
--
-- WHAT ONLY STAFF ACTUALLY NEEDED FROM daily_logs, AND WHAT THIS GIVES THEM
-- Grepping every staff-reachable screen that reads dailyLogs turns up: "has
-- today's end-of-day already been submitted" (staff menu), "pre-fill if
-- resubmitting today" (End of day screen), and "show the counted/cash row on
-- a printed stock sheet" (which staff CAN view for a past date they pick, not
-- only today). Nothing staff-facing needs another shop's data, and nothing
-- needs the entire all-time history. staff_recent_daily_logs(p_shop_id)
-- below returns just that one shop's logs from the last 60 days - covers
-- today's check with room to spare, and covers the stock sheet for any
-- recent date. A staff-facing stock sheet printed for a date OLDER than 60
-- days will show "not submitted" for the counted/cash row even if a log
-- exists further back - a real but minor regression, and the tradeoff the
-- owner explicitly signed off on ("recent logs is fine for now"). Widen the
-- window later if that turns out to matter in practice.
-- This function is still callable by anyone with the anon key, same as
-- staff_login and every other staff_* RPC - staff are never authenticated
-- Supabase Auth users, so "admin-only" isn't an option here. The win is
-- narrowing from "every shop, forever" to "one named shop, 60 days," not
-- eliminating anon access entirely - that ceiling is inherent to how staff
-- sign in today, not something this file can fix.
--
-- WHAT THIS ADDS OR CHANGES
--   staff_read_names        — DROPPED.
--   staff_admin_read        — new policy: admin-only SELECT on the real
--                              staff table (is_admin(), same guard as every
--                              admin_* function). Lets the admin Settings
--                              staff list keep reading the real table
--                              exactly as it does today.
--   staff.pin                — drop column if exists (no-op today; see
--                              reality check above).
--   daily_logs_anon_read     — DROPPED.
--   staff_recent_daily_logs  — new SECURITY DEFINER function: one shop's
--                              daily_logs from the last 60 days. See above.
--
-- WHAT THIS LEAVES ALONE
--   staff_public and the three functions from Part 1 - untouched here,
--   already correct. staff_public keeps working after this file because it
--   bypasses RLS via its own ownership, not via staff_read_names - dropping
--   that policy doesn't affect it.
--   daily_logs_admin_all - untouched. Admin keeps full read/write on
--   daily_logs exactly as today; only the anon-wide-open policy is removed.
--   Every other table's policies - see the full audit below, delivered
--   alongside this file in the chat, not repeated here.
--   Realtime push for daily_logs changes will quietly stop reaching staff
--   devices after this runs (Supabase Realtime only forwards a change to a
--   client that could still SELECT the row under RLS, and staff no longer
--   can, directly). The app's own code already treats realtime as a
--   best-effort snappiness upgrade with the 15-second poll as the real
--   sync mechanism, so this doesn't break anything - noting it so it isn't
--   mistaken for a bug later if it's ever noticed.
-- ============================================================================

drop policy if exists staff_read_names on staff;

create policy staff_admin_read on staff for select using (is_admin());

-- No-op today (no `pin` column exists) - kept only so a future accidental
-- reintroduction of a plaintext column doesn't survive unnoticed.
alter table staff drop column if exists pin;

drop policy if exists daily_logs_anon_read on daily_logs;

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

-- ============================================================================
-- Done. After this runs: confirm a staff device can still sign in (reads
-- staff_public, unaffected); that the staff menu correctly shows today's
-- business-day/end-of-day status (reads staff_recent_daily_logs now); and
-- that Settings' staff list still works for admin (reads staff directly,
-- now admin-gated instead of wide open).
-- ============================================================================
