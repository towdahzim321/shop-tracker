-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 4: explicit write-grant
-- revoke on staff read views (staff_public, phones_staff_view,
-- ledger_staff_view)
-- ============================================================================
-- PRODUCTION ONLY. Staging's actual grants are a separate, later pass — not
-- touched here. Does not enable FORCE ROW LEVEL SECURITY on anything; the
-- staff RPCs are SECURITY DEFINER and depend on the owner-exemption these
-- views also rely on, so that's deliberately its own separate pass.
--
-- WHY THIS EXISTS
-- A staff-id trust-surface investigation flagged (via
-- supabase-schema-security-3-lockdown-staff-views.sql, drafted and verified
-- against STAGING only) that staff_public/phones_staff_view/ledger_staff_view
-- carry INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER grants to anon on
-- top of SELECT — all three are plain views owned by postgres, over
-- staff/phones/ledger, and (by design, unchanged here) bypass those base
-- tables' admin-only RLS policies via view-ownership: the base tables have
-- RLS enabled but not FORCEd, owner postgres, so a query through a
-- postgres-owned view never evaluates the base table's row policies,
-- regardless of who runs the query.
--
-- Verified directly against PRODUCTION before writing this file (two ways —
-- information_schema.role_table_grants and has_table_privilege() — not just
-- the staging finding):
--   anon/authenticated/public: INSERT=false, UPDATE=false, DELETE=false,
--   SELECT=true, on all three views. Production does NOT have the write-
--   grant hole staging has today — security-3 as drafted does not apply
--   here and is not being run. Also confirmed via grep of index.html: the
--   only .update(/.insert(/.delete( call anywhere in the client is
--   sb.from('settings').update(...) at index.html:622 — nothing ever writes
--   through these three views.
--
-- What production DOES have, identically to staging: an
-- ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public entry
-- (pg_default_acl) granting anon/authenticated full arwdDxtm on any relation
-- postgres newly creates in public — RLS still gates a normal new TABLE
-- despite that grant, but a postgres-owned VIEW over an RLS table bypasses
-- RLS entirely, so a freshly-created view is fully anon-writable at the row
-- level from the moment it exists, unless explicitly revoked.
-- CREATE OR REPLACE VIEW against an EXISTING view preserves its current
-- grants and does not re-consult default privileges; a fresh CREATE VIEW
-- (a DROP + CREATE, or any rebuild where the view doesn't already exist)
-- does. Production's three views have only ever been touched via
-- CREATE OR REPLACE VIEW on an already-existing view (supabase-schema-
-- part5b-staffview.sql:70, supabase-schema-security-1.sql:118) — the only
-- reason they're clean today, not a durable guarantee on its own.
--
-- This file makes that clean state explicit and durable instead of an
-- accident of every past change having used CREATE OR REPLACE on a view
-- that already existed. No functional change: the REVOKE below removes
-- privileges anon/authenticated/public do not currently hold (confirmed
-- above). See the AGENTS.md "Grants" note added alongside this file for the
-- general rule this instance falls under.
--
-- Uses REVOKE ALL rather than an enumerated privilege list: PG17 (confirmed
-- live — select version() returned PostgreSQL 17.6) added MAINTAIN (the `m`
-- in arwdDxtm) as a real, separately-grantable privilege, so an enumerated
-- `revoke insert, update, delete, truncate, references, trigger` would leave
-- MAINTAIN behind and not fully clear the ACL. REVOKE ALL + GRANT SELECT in
-- one transaction is complete and leaves no window where SELECT is briefly
-- absent.
-- ============================================================================

begin;

revoke all on staff_public, phones_staff_view, ledger_staff_view
  from public, anon, authenticated;

grant select on staff_public, phones_staff_view, ledger_staff_view
  to anon, authenticated;

commit;

-- ----------------------------------------------------------------------------
-- REUSABLE BLOCK — run this immediately after any future DROP + CREATE (not
-- CREATE OR REPLACE-in-place) of staff_public, phones_staff_view, or
-- ledger_staff_view, or of any new view added to public. See AGENTS.md
-- "Grants".
-- ----------------------------------------------------------------------------
-- begin;
-- revoke all on <view> from public, anon, authenticated;
-- grant select on <view> to anon, authenticated;  -- or narrower, per the view's intended readers
-- commit;

-- VERIFY AFTER RUNNING — full relacl, not just a grant count, so the exact
-- remaining ACL string is visible.
--   select relname, relacl
--   from pg_class
--   where relnamespace = 'public'::regnamespace
--     and relname in ('staff_public','phones_staff_view','ledger_staff_view')
--   order by relname;
-- Expected: each row's relacl contains anon=r/postgres and
-- authenticated=r/postgres (SELECT only), plus postgres's own owner
-- entries — no a/w/d/D/x/t/m for anon/authenticated, and no entry for
-- public at all.
