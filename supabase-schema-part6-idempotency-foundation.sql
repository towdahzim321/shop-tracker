-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6: idempotency foundation
-- Phase 4a (plumbing) — step 1 of the ordered rollout, additive only
-- ============================================================================
-- Run this first, on its own, before touching any staff_/admin_ function.
-- Purely additive - one new table, one new index, two new helper functions.
-- Nothing that exists today changes behaviour. Safe to re-run (create
-- table/index if-not-exists, function or-replace throughout).
--
-- WHY THIS EXISTS
-- Every staff_/admin_ write function was checked against the real definitions
-- in backups/schema.dump.sql (not reconstructed) for how it behaves on a
-- client retry after a dropped connection - the scenario a slow shop-floor
-- connection makes routine, not theoretical. Three concrete failure classes
-- were found:
--   - staff_sell_phone / staff_return_phone / staff_close_day guard on the
--     row's current status, so a retry of a call that actually succeeded
--     shows staff a confusing "no longer available" error for their own
--     successful action.
--   - 8 admin actions (admin_mark_repaired, admin_undo_return,
--     admin_undo_sale, admin_write_off, admin_confirm_cash,
--     admin_delete_phone, admin_delete_log, admin_set_pricing_batch) have no
--     such guard at all - a retry silently writes a second ledger audit row
--     for one real action.
--   - admin_cash_adjustment has the same gap, except a duplicate there is a
--     duplicated cash figure, not just a duplicated audit row.
-- This file adds nothing to fix any of that yet - it only adds the shared
-- machinery every later step in this phase will use to fix it the same way
-- everywhere, rather than once per function.
--
-- SCOPE — READ THIS BEFORE RUNNING
-- This is Phase 4a specifically. Deliberately NOT in it, so none of this
-- gets lost or silently assumed to be covered by "the idempotency work":
--   - the localStorage send-queue and "N entries waiting to send"
--   - save buttons locking on tap
--   - incremental sync instead of full reloads every 15 seconds
--   - the service worker
--   - admin_find_duplicate_receipts / admin_remove_duplicate_receipts for
--     the rows already in stock
--   - real staff sessions (section 00 on the build order page)
--   - A GENUINE DOUBLE-TAP AFTER A SUCCESS. Idempotency protects a RETRY of
--     ONE submission - same key, same attempt. It does nothing for a second,
--     deliberate tap after the first one already succeeded: that generates
--     a fresh key and is, correctly, a new action. Today the (imei, model)
--     rule and the staff_sell_phone/staff_return_phone status guards happen
--     to catch most double-taps in this app as a side effect, but that's
--     coincidence, not this mechanism, and a future write path without an
--     equivalent natural guard - Phase 5 expenses, for one - would not be
--     protected by either. The save-button lock in Phase 4b is what
--     actually covers double-tap. Nobody should read "Phase 4a shipped" as
--     "double-taps are handled."
-- Phase 4a is server-side write-path deduplication only, function by
-- function, client cutover last.
--
-- THE MECHANISM
-- idempotency_begin(p_key, p_fn): tries to insert the key. A null key always
-- proceeds (returns null) - so every function converted in this phase stays
-- 100% backward compatible with the CURRENT client, which sends nothing,
-- until the client is deliberately changed to send one (last step of this
-- phase, after every function below has shipped). A real, previously-unseen
-- key also proceeds (returns null). A key already seen returns the stored
-- result instead, so the caller can short-circuit rather than redo the write.
--
-- CALLER-SIDE RULE — read this before converting any function
-- idempotency_begin's return value must always be tested with `IS NOT NULL`,
-- never treated as truthy/falsy. Only a genuine SQL NULL means "proceed,
-- this key is new." Everything else - including the literal JSON scalar
-- null, which is what coalesce(v_result, 'null'::jsonb) below returns for a
-- seen key whose stored result happens to be empty - means "this key was
-- already claimed, do not repeat the write." A function written as
-- `if v_seen is null or v_seen = 'null'::jsonb then ... end if;` would
-- silently defeat the whole mechanism: JSON null is not the same thing as
-- "nothing happened," it's still "this key exists, don't redo the write."
-- The one correct check, every time: `if v_seen is not null then <derive
-- the return value from v_seen and return early>; end if;` then proceed.
--
-- idempotency_finish(p_key, p_result): records the outcome. Must be the
-- last statement on every success path of every converted function, with no
-- early return between begin and finish - see CONCURRENCY below for why
-- that specific discipline matters, not just tidiness.
--
-- CONCURRENCY - what happens if the SAME key arrives twice while the first
-- call is still running (a slow link is exactly when this happens, not an
-- edge case)
-- The second call's insert inside idempotency_begin blocks on the unique
-- index until the first call's transaction resolves - this is standard
-- Postgres MVCC behaviour for a unique constraint, not anything added here.
--   - First call commits: the second's blocked insert then sees a real
--     conflict, raises unique_violation, and reads the row - which is by
--     definition fully committed at that point, including whatever
--     idempotency_finish wrote, since that update happened inside the SAME
--     transaction as the insert the second call just waited on. The second
--     caller can never observe a half-finished row or a null result for a
--     key that's actually in flight.
--   - First call rolls back (e.g. a business-rule refusal partway through):
--     the insert is invisible once rolled back, so the second call's insert
--     proceeds as if it were first, and does the real work.
-- This is why idempotency_finish must be unconditionally last on every
-- success path - if a function returned early after begin but before finish
-- on some code path, a concurrent second caller blocked on that key would
-- eventually see a committed row with result still null, and there would be
-- nothing correct to hand back. Each function converted in this phase will
-- be checked against this rule individually.
--
-- RETENTION - inline in idempotency_begin, not a scheduled job
-- Deletes rows older than 7 days, AFTER the null-key check so today's
-- unmodified client - which sends no key on every write - never pays for
-- this scan at all; only a call that actually carries a key does. Backed by
-- idempotency_keys_created_at_idx below, so it's an index range scan, not a
-- sequential scan of the whole table.
-- Considered and rejected: a pg_cron job or external scheduler, which is one
-- more piece of infrastructure that can silently stop firing on a free-tier
-- project with no monitoring, and nobody would notice for months. Write
-- volume here is a few dozen actions a day across three shops, so this
-- indexed delete-by-age costs nothing measurable - cleanup happens as a
-- byproduct of normal use instead of something to configure or remember.
--
-- ACCESS - internal helpers only, never callable directly with the anon key
-- Postgres grants EXECUTE on a new function to PUBLIC by default, which
-- would let anyone holding the publishable key call idempotency_finish
-- directly and poison a stored result, or insert junk keys. Both grants are
-- explicitly revoked below. The staff_/admin_ functions that call these two
-- keep working regardless - a SECURITY DEFINER function runs as its owner,
-- so its internal calls are checked against the owner's privileges (which
-- include everything the owner owns, revoke-from-public or not), never
-- against the original caller's. Also SECURITY DEFINER themselves, both with
-- search_path pinned - the same hardening already applied to every other
-- SECURITY DEFINER function in this schema during the security phase, and
-- these two are now among the most-privileged objects in it.
--
-- VERIFY AFTER RUNNING (both should be true)
--   1) select has_function_privilege('anon', 'idempotency_begin(uuid,text)', 'EXECUTE');
--      select has_function_privilege('anon', 'idempotency_finish(uuid,jsonb)', 'EXECUTE');
--      -- both false
--   2) select indexname from pg_indexes where tablename = 'idempotency_keys';
--      -- idempotency_keys_pkey and idempotency_keys_created_at_idx both present
-- ============================================================================

create table if not exists idempotency_keys (
  key uuid primary key,
  fn text not null,
  created_at timestamptz not null default now(),
  result jsonb
);

create index if not exists idempotency_keys_created_at_idx
  on idempotency_keys (created_at);

-- Only the functions that use it ever read/write this table, all via
-- SECURITY DEFINER (same as every write function in this schema), so no
-- grant to anon/authenticated and no RLS policy - matches how shop_resets
-- and model_audit are already handled.
alter table idempotency_keys enable row level security;

create or replace function idempotency_begin(p_key uuid, p_fn text)
returns jsonb -- null: brand new key, caller should do the real work.
              -- non-null: this exact attempt was already processed, caller
              -- should short-circuit and use this as the result instead.
              -- ALWAYS test with `is not null` - see CALLER-SIDE RULE above.
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_result jsonb;
begin
  if p_key is null then
    return null; -- no key sent (old client, or a caller that opts out) - always proceed, unchanged from today's behaviour, no cleanup cost paid
  end if;

  delete from idempotency_keys where created_at < now() - interval '7 days';

  begin
    insert into idempotency_keys (key, fn) values (p_key, p_fn);
    return null; -- inserted clean: genuinely new, proceed
  exception when unique_violation then
    -- Blocks here until the holder of this key commits or rolls back (see
    -- CONCURRENCY above) - by the time this SELECT runs, the row is either
    -- fully committed with its real result, or this exception was never
    -- reached because the insert above succeeded once the other transaction
    -- rolled back.
    select result into v_result from idempotency_keys where key = p_key;
    return coalesce(v_result, 'null'::jsonb);
  end;
end; $$;

create or replace function idempotency_finish(p_key uuid, p_result jsonb)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  update idempotency_keys set result = p_result where key = p_key and p_key is not null;
$$;

revoke execute on function idempotency_begin(uuid, text) from public;
revoke execute on function idempotency_finish(uuid, jsonb) from public;

-- ============================================================================
-- Done. Nothing existing changes behaviour - no staff_/admin_ function calls
-- either of these yet. Next: the pilot conversion, staff_sell_phone, in its
-- own file, proving the pattern once in full (SQL + mock + a test that calls
-- it twice with the same key and asserts only one effect) before repeating
-- it across the other 19 write functions in risk order.
-- ============================================================================
