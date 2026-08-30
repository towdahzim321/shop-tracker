-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 9: make the staff session
-- token mandatory
-- ============================================================================
-- Closes the finding from the security audit: require_staff_session's
-- null-token branch ("if p_session_token is null then return
-- staff_of_shop(p_staff_id, p_shop_id); end if;") let anyone holding the
-- anon key call any of the seven staff RPCs with no PIN and no session at
-- all, as long as they supplied a real (freely-readable via staff_public)
-- staff_id for the target shop - staff_of_shop is an existence/active/
-- shop-match lookup, not a credential check. Proven live against staging in
-- the audit: a real $0.01 sale, fully attributed, zero credentials.
--
-- Same function's mismatch check ("if p_staff_id is not null and p_staff_id
-- <> v_session.staff_id then raise") also let a caller holding a VALID
-- token pass p_staff_id: null and skip the match entirely, landing NULL in
-- sold_by/received_by/submitted_by/ledger.by_staff (all nullable) instead
-- of a real attribution. Both fixed here, same function, one migration.
--
-- CHECKED LIVE BEFORE WRITING THIS FILE
-- - require_staff_session's signature is byte-identical on production and
--   staging: (p_session_token uuid, p_staff_id uuid, p_shop_id text)
--   returns text, search_path already pinned to 'public','pg_temp'.
--   BODY-ONLY change - no DROP FUNCTION, no NOTIFY pgrst needed (that's
--   only required for signature changes, per AGENTS.md).
-- - index.html's isSessionAuthError() (line 828-830) matches on the
--   substrings 'session has expired' and 'does not match the signed-in
--   staff' - the new missing-token branch raises the first phrase so the
--   client's existing outbox-pause/re-auth-banner path fires with zero
--   client-side change. index.html is not touched by this migration.
-- - All seven staff RPCs and the live client already unconditionally send
--   a real, non-null session token on every call, on both databases, as of
--   right now - there is no remaining legitimate caller relying on the
--   null-token fallback this file removes.
-- ============================================================================

create or replace function require_staff_session(p_session_token uuid, p_staff_id uuid, p_shop_id text)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_session staff_sessions%rowtype;
begin
  if p_session_token is null then
    raise exception 'Your session has expired. Please sign in again.';
  end if;

  select * into v_session from staff_sessions where token = p_session_token;
  if v_session.token is null or v_session.expires_at < now() then
    raise exception 'Your session has expired. Please sign in again.';
  end if;

  if p_staff_id is null or p_staff_id <> v_session.staff_id then
    raise exception 'This session does not match the signed-in staff member.';
  end if;

  update staff_sessions set expires_at = now() + interval '12 hours'
    where token = p_session_token;

  return staff_of_shop(v_session.staff_id, p_shop_id);
end;
$$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
  pg_get_function_result(p.oid) as returns, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'require_staff_session';
-- Expect: unchanged args/returns/proconfig vs. before this file.

select pg_get_functiondef(oid) from pg_proc where proname = 'require_staff_session';
-- Expect: the body above, live.

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's CRLF note, pipe
-- through stdin:
--   cat supabase-schema-security-9-require-staff-session-mandatory.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-9-require-staff-session-mandatory.sql | psql "$DATABASE_URL" -f -
-- Verify against staging (re-run the audit's exploit, expect it to now
-- fail, then drive a real staff sale through index.staging.html end to
-- end and confirm it still succeeds) BEFORE applying to production. Only a
-- read-only verification query runs against production - no exploit
-- attempt or write test, ever, on $DATABASE_URL.
-- ============================================================================
