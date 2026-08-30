-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Rollback for Security Part 9
-- ============================================================================
-- Reverts supabase-schema-security-9-require-staff-session-mandatory.sql
-- exactly: restores require_staff_session's null-token fallback and the
-- "is not null and" mismatch guard - byte-identical to what was live
-- immediately before security-9, pulled via pg_get_functiondef on both
-- production and staging just before writing that file (confirmed
-- identical on both), reproduced here verbatim, not retyped from memory.
--
-- Body-only, same as the forward migration: no signature change, so this
-- is CREATE OR REPLACE, not DROP + CREATE, and no NOTIFY pgrst is needed.
-- Restoring this reopens the anon-key session bypass the forward migration
-- closed - only use this if security-9 itself turns out to break something,
-- not as a routine operation.
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
    return staff_of_shop(p_staff_id, p_shop_id);
  end if;

  select * into v_session from staff_sessions where token = p_session_token;
  if v_session.token is null or v_session.expires_at < now() then
    raise exception 'Your session has expired. Please sign in again.';
  end if;

  if p_staff_id is not null and p_staff_id <> v_session.staff_id then
    raise exception 'This session does not match the signed-in staff member.';
  end if;

  update staff_sessions set expires_at = now() + interval '12 hours'
    where token = p_session_token;

  return staff_of_shop(v_session.staff_id, p_shop_id);
end;
$$;

-- ============================================================================
-- VERIFICATION (run after applying)
-- ============================================================================
select pg_get_functiondef(oid) from pg_proc where proname = 'require_staff_session';
-- Expect: the null-token fallback and "is not null and" guard both restored.

-- ============================================================================
-- APPLY: staging first, then production, if ever needed. Per AGENTS.md's
-- CRLF note, pipe through stdin:
--   cat supabase-schema-security-9-rollback.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-9-rollback.sql | psql "$DATABASE_URL" -f -
-- ============================================================================
