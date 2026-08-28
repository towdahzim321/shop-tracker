-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 7: staff_sessions table +
-- staff_login issues a session
-- ============================================================================
-- ADDITIVE ONLY. No staff business RPC (staff_open_day/close_day/
-- sell_phone/return_phone/receive_stock/submit_eod/log_expense) is touched
-- in this file - none of them verify a session token yet. This file only
-- creates the table and makes staff_login start issuing a session alongside
-- the identity it already returns. First concrete step of moving staff off
-- trusting a client-supplied p_staff_id (see the earlier options review);
-- building option A2 (DB-backed session table, sliding expiry to be added
-- next pass once the RPCs start verifying tokens).
--
-- CHECKED LIVE BEFORE WRITING THIS FILE
-- - No dependents on staff_login (pg_depend query against production came
--   back empty) - safe to DROP FUNCTION + CREATE, no other object breaks.
-- - Every other shop_id column in this schema (staff, phones,
--   business_days, daily_logs, expenses, ledger) has an FK to shops(id) -
--   matched for staff_sessions.shop_id.
-- - postgres and service_role both have rolbypassrls = true; anon and
--   authenticated do not (confirmed via pg_roles). So "RLS enabled, zero
--   policies" is sufficient on its own to fully deny anon/authenticated on
--   staff_sessions while every SECURITY DEFINER function (owned by
--   postgres) reads/writes it freely as owner. No FORCE ROW LEVEL SECURITY
--   used or needed here.
-- - None of the six existing FKs to staff.id specify ON DELETE CASCADE -
--   matched for staff_sessions.staff_id (there's no staff-deletion RPC in
--   this schema anyway; admin_deactivate_staff only flips `active`).
-- ============================================================================

create table staff_sessions (
  token uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff(id),
  shop_id text not null references shops(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

alter table staff_sessions enable row level security;
-- Deliberately zero policies: RLS enabled + no policy denies every row to
-- every non-owner, non-BYPASSRLS role (anon, authenticated) - confirmed
-- live above. Tokens are live credentials; anon/authenticated must never
-- read this table. Schema default privileges still hand anon/authenticated
-- a coarse table grant (the same mechanism documented in AGENTS.md's
-- "Grants" section) but that grant is moot here - RLS denies every row
-- regardless of it, unlike the view-ownership-bypass case that note
-- describes.

-- ============================================================================
-- staff_login: return type changes (gains session_token, expires_at), so
-- Postgres itself refuses CREATE OR REPLACE here ("cannot change return
-- type of existing function") - DROP FUNCTION + CREATE + NOTIFY pgrst,
-- matching the exact incantation already used in
-- part6b-drop-old-overload.sql / part6d / part6e. Parameters are unchanged
-- (p_staff_id uuid, p_pin text) - only what it returns changes.
--
-- TTL cleanup follows the same pattern idempotency_begin already uses: an
-- unconditional delete inline at the top of the function, run on every
-- call. One difference from idempotency_keys' created_at-based cleanup:
-- this one keys off expires_at, not created_at, because next pass adds
-- sliding expiry (extending expires_at on use) - a created_at-based
-- cleanup would delete a still-valid, recently-extended session just
-- because it's old.
--
-- On a PIN mismatch / inactive / unknown staff id, behaviour is unchanged
-- from before this file: zero rows returned, and now also no session row
-- created.
-- ============================================================================

drop function staff_login(uuid, text);

create function staff_login(p_staff_id uuid, p_pin text)
returns table(id uuid, name text, shop_id text, session_token uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff staff%rowtype;
  v_token uuid;
  v_expires timestamptz;
begin
  -- staff_sessions.expires_at qualified with the table name: RETURNS
  -- TABLE(...) implicitly declares id/name/shop_id/session_token/
  -- expires_at as OUT-parameter variables in this function's scope, so an
  -- unqualified `expires_at` here is ambiguous between that variable and
  -- the column (caught live on staging - see security-7's apply history).
  delete from staff_sessions where staff_sessions.expires_at < now();

  select s.* into v_staff from staff s
    where s.id = p_staff_id and s.active
      and s.pin_hash = crypt(p_pin, s.pin_hash);
  if v_staff.id is null then
    return;
  end if;

  v_expires := now() + interval '12 hours';
  insert into staff_sessions (staff_id, shop_id, expires_at)
    values (v_staff.id, v_staff.shop_id, v_expires)
    returning token into v_token;

  return query select v_staff.id, v_staff.name, v_staff.shop_id, v_token, v_expires;
end;
$$;

notify pgrst, 'reload schema';

-- ============================================================================
-- No client change this pass. index.html's staff_login call site
-- (sb.rpc('staff_login', {p_staff_id, p_pin}), around line 1873) reads only
-- data[0].id/name/shop_id (line 1882-1883) and ignores unknown extra
-- columns - session_token/expires_at are simply unread until the next
-- pass wires the outbox/RPC calls to attach the token at send time.
-- ============================================================================

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select p.proname, pg_get_function_result(p.oid) as return_type
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_login';

select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'staff_sessions'
order by ordinal_position;

select relrowsecurity, relforcerowsecurity
from pg_class
where relname = 'staff_sessions' and relnamespace = 'public'::regnamespace;

select policyname from pg_policies where tablename = 'staff_sessions';
-- expect zero rows

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's corrected CRLF
-- note, pipe through stdin:
--   cat supabase-schema-security-7-staff-sessions.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-7-staff-sessions.sql | psql "$DATABASE_URL" -f -
-- ============================================================================
