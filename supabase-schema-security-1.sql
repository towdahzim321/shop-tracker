-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 1: stop leaking pin_hash
-- ============================================================================
-- Run this any time. Nothing breaks. The staff login flow keeps working
-- exactly as it does today, for every existing staff member, with zero
-- downtime and zero re-entry of PINs.
--
-- WHY THIS EXISTS
-- pg_policies shows staff_read_names on the staff table: roles {public},
-- cmd SELECT, qual true. RLS is row-level, not column-level, so that policy
-- doesn't just let the app read staff names for the picker - it lets ANYONE
-- holding the publishable key (which sits in the page source of the live
-- Netlify site, openly, by design) run `select * from staff` and pull back
-- pin_hash for every staff member at every shop. That's true even though the
-- PINs are hashed: a 4-6 digit PIN has so few possibilities that an offline
-- attacker can brute-force a bcrypt hash of one in well under a second per
-- guess, so "hashed" barely narrows the exposure for a keyspace this small.
-- The fix is to stop exposing the column at all, not to hash it harder.
--
-- REALITY CHECK — READ THIS BEFORE RUNNING
-- The original plan for this file assumed the database still had a plain
-- `pin` column alongside a new `pin_hash`, needing a backfill and a
-- transitional staff_login that accepts either. The actual live schema,
-- confirmed by running pg_get_functiondef and information_schema.columns
-- just before writing this file, is NOT that:
--   - staff.pin_hash already exists and is NOT NULL. There is no `pin`
--     column at all - not nullable, not present, nothing to migrate off.
--   - staff_login, admin_set_staff_pin and admin_reset_staff_pin already
--     hash exclusively via crypt()/gen_salt('bf'). There was never a
--     plaintext PIN in this database for this file to be "backward
--     compatible" with.
-- So: no ALTER TABLE ADD COLUMN, no backfill UPDATE, and no dual-mode
-- staff_login - none of that would do anything (or, in the backfill's case,
-- would fail outright: `crypt(pin, ...)` referencing a `pin` column that
-- doesn't exist). What this file actually does is narrower and smaller than
-- first planned: create the column-filtered view the app should have been
-- reading from, and pin an explicit search_path onto the three functions
-- below - copied verbatim from what is live right now, logic unchanged - so
-- a SECURITY DEFINER function can't be tricked by a caller-controlled
-- search_path into resolving crypt/gen_salt or `staff` from somewhere else.
--
-- WHAT THIS ADDS OR CHANGES
--   pgcrypto        — ensured present (already is, in practice; this is a
--                      no-op if it's already installed anywhere, which it
--                      must be for the existing functions to work at all).
--   staff_public     — new view: id, name, shop_id, active only. No
--                      pin_hash. security_invoker = false so it reads with
--                      the view owner's rights and bypasses RLS on the base
--                      table - the same pattern already in production for
--                      phones_staff_view and ledger_staff_view.
--   staff_login, admin_set_staff_pin, admin_reset_staff_pin — re-created
--                      with an explicit search_path added. Bodies are
--                      otherwise byte-for-byte what pg_get_functiondef
--                      returned for each just before this file was written.
--
-- WHAT THIS LEAVES ALONE
--   The staff_read_names policy - still in place after this file. Nothing
--   in the app is switched over to staff_public yet either (that's the
--   separate index.html change, delivered alongside this file but not part
--   of it). Both stay as they are until Part 2 runs. No DROP of any policy
--   or column happens in this file, on any table.
--   The daily_logs_anon_read policy exposing `cash` - flagged in this
--   session's findings, not touched here, out of scope for the staff/pin fix.
--   The shops table shape - a separate open question for when Phase 3
--   (shops/models) is revisited; not touched by this file.
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
-- ensureStaffNames now read staff_public instead of staff). Once that's live
-- and confirmed working, run supabase-schema-security-2.sql to actually
-- close off staff_read_names.
-- ============================================================================
