-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 11: lock staff_login out
-- after repeated wrong PINs, enforce PIN format server-side
-- ============================================================================
-- Closes a finding from the security audit: staff_login has no attempt
-- counter, no lockout, no delay - proven live against staging with 15
-- sequential + 40 truly-concurrent wrong-PIN attempts, all HTTP 200, zero
-- throttling, zero 429s. The real PIN policy is 6-8 digits, but that floor
-- was enforced only in client JS (index.html:4178,4342,4350) -
-- admin_set_staff_pin/admin_reset_staff_pin applied no server-side check at
-- all, so nothing stopped a caller who already has an admin session from
-- setting (or resetting) a PIN below that floor via a direct RPC call.
--
-- POLICY: 5 consecutive wrong PINs locks that staff_id for 15 minutes,
-- reset on either a correct PIN or an admin PIN reset. This does not track
-- by IP (none available through PostgREST) - it's a per-staff-id lockout,
-- which means a caller who already knows a valid staff_id (freely readable
-- via staff_public, by design - see the audit) can keep that one staff
-- member locked out by repeatedly failing their PIN. Accepted trade-off:
-- an account-lockout DoS is a much smaller, much more visible problem than
-- an unthrottled PIN oracle, and the owner can always clear it early via
-- admin_reset_staff_pin.
--
-- Additive-only (two new nullable/defaulted columns on staff, two body-only
-- CREATE OR REPLACE, no signature changes anywhere) - single file, no
-- 3-step split needed per AGENTS.md (that rule is for POLICY/COLUMN
-- REMOVALS, not additions).
--
-- staff_login's row lookup now takes FOR UPDATE before reading/incrementing
-- the attempt counter, so concurrent wrong guesses against the same staff
-- serialize instead of racing and losing increments - matches the FOR
-- UPDATE convention every other mutating RPC in this schema already uses
-- for the row it's about to change.
--
-- Existing PINs (including the staging test staff's 4-digit "4291", noted
-- in AGENTS.md) are untouched - the new 6-8-digit format check only runs
-- when a PIN is SET, not on login, so nothing already stored needs to
-- change or gets locked out by this migration itself.
-- ============================================================================

alter table staff
  add column if not exists failed_pin_attempts int not null default 0,
  add column if not exists pin_locked_until timestamptz;

create or replace function public.staff_login(p_staff_id uuid, p_pin text)
returns table(id uuid, name text, shop_id text, session_token uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff staff%rowtype;
  v_token uuid;
  v_expires timestamptz;
  v_new_attempts int;
  v_wait_seconds int;
begin
  delete from staff_sessions where staff_sessions.expires_at < now();

  select * into v_staff from staff where staff.id = p_staff_id and staff.active for update;
  if v_staff.id is null then
    return;
  end if;

  if v_staff.pin_locked_until is not null and v_staff.pin_locked_until > now() then
    v_wait_seconds := ceil(extract(epoch from (v_staff.pin_locked_until - now())))::int;
    raise exception 'Too many incorrect PIN attempts. Try again in % minute(s).', greatest(1, ceil(v_wait_seconds / 60.0))::int;
  end if;

  if v_staff.pin_hash <> crypt(p_pin, v_staff.pin_hash) then
    v_new_attempts := v_staff.failed_pin_attempts + 1;
    if v_new_attempts >= 5 then
      update staff set failed_pin_attempts = 0, pin_locked_until = now() + interval '15 minutes'
        where staff.id = v_staff.id;
    else
      update staff set failed_pin_attempts = v_new_attempts
        where staff.id = v_staff.id;
    end if;
    return;
  end if;

  update staff set failed_pin_attempts = 0, pin_locked_until = null where staff.id = v_staff.id;

  v_expires := now() + interval '12 hours';
  insert into staff_sessions (staff_id, shop_id, expires_at)
    values (v_staff.id, v_staff.shop_id, v_expires)
    returning token into v_token;

  return query select v_staff.id, v_staff.name, v_staff.shop_id, v_token, v_expires;
end;
$$;

create or replace function public.admin_set_staff_pin(p_shop_id text, p_name text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if p_pin !~ '^[0-9]{6,8}$' then raise exception 'PIN must be 6 to 8 digits.'; end if;
  insert into staff (shop_id, name, pin_hash)
    values (p_shop_id, p_name, crypt(p_pin, gen_salt('bf')))
    returning id into v_id;
  return v_id;
end; $$;

create or replace function public.admin_reset_staff_pin(p_staff_id uuid, p_new_pin text)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
begin
  perform require_admin();
  if p_new_pin !~ '^[0-9]{6,8}$' then raise exception 'PIN must be 6 to 8 digits.'; end if;
  update staff set pin_hash=crypt(p_new_pin, gen_salt('bf')), active=true,
    failed_pin_attempts=0, pin_locked_until=null
    where id=p_staff_id;
end; $$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select column_name, data_type, column_default, is_nullable
from information_schema.columns
where table_schema='public' and table_name='staff'
  and column_name in ('failed_pin_attempts','pin_locked_until');
-- Expect: failed_pin_attempts int, default 0, not null; pin_locked_until
-- timestamptz, nullable, no default.

select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_login','admin_set_staff_pin','admin_reset_staff_pin');
-- Expect: unchanged args/proconfig vs. before this file (body-only change).

select pg_get_functiondef(oid) from pg_proc where proname = 'staff_login';
select pg_get_functiondef(oid) from pg_proc where proname = 'admin_set_staff_pin';
select pg_get_functiondef(oid) from pg_proc where proname = 'admin_reset_staff_pin';
-- Expect: the bodies above, live.

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's CRLF note, pipe
-- through stdin:
--   cat supabase-schema-security-11-staff-login-lockout.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-11-staff-login-lockout.sql | psql "$DATABASE_URL" -f -
-- Verify against staging: 5 wrong PINs against the staging test staff locks
-- the account, a 6th attempt (even the real PIN) gets the lockout message.
-- admin_set_staff_pin/admin_reset_staff_pin's format check cannot be
-- exercised through PostgREST without a real admin Auth session (none
-- available) - verified by reading the body plus standalone regex checks
-- instead. No write or exploit test of any kind runs against $DATABASE_URL.
-- ============================================================================
