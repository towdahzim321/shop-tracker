-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6d: staff_return_phone, idempotent
-- Phase 4a (plumbing) — step 3 (staff_sell_phone was step 2, part 6a)
-- ============================================================================
-- Run this AFTER part 6 (the idempotency foundation). Safe to re-run
-- (create or replace, drop if-exists).
--
-- SAME SHAPE AS PART 6A
-- Single row read-modify-write, single ledger insert, void return, and an
-- existing status guard ('This phone is not currently marked as sold.')
-- that already makes a retry's SYMPTOM visible today - a genuine return
-- retried after a network hang gets that refusal for their own prior
-- success. Wrapped exactly like staff_sell_phone in part 6a.
--
-- WHAT CHANGED FROM THE LIVE FUNCTION (verified against
-- backups/schema.dump.sql - not reconstructed, lines 549-572)
-- Exactly one addition: a p_idempotency_key parameter (default null, so
-- every existing caller - including the current deployed client, which sends
-- nothing - keeps working exactly as before), and the begin/finish calls
-- required to use it. The 6 existing statements in the body (staff_of_shop,
-- require_day_open, the two status checks, the update, the ledger insert)
-- are untouched, same order, same text.
--
-- idempotency_finish is the last statement on the only success path - there
-- is no early return between idempotency_begin and it, per the discipline in
-- part 6's header.
--
-- A seen key returns void with no error - correct here for the same reason
-- as part 6a: the client only cares whether res.ok is true, nothing here
-- stores or replays a displayed value.
--
-- THE PART 6B TRAP, AVOIDED THIS TIME
-- `create or replace function` only replaces a function whose name AND FULL
-- parameter type list match exactly. Adding p_idempotency_key changes the
-- signature, so without an explicit drop of the old 7-parameter overload,
-- Postgres would keep BOTH versions around and PostgREST would fail to
-- resolve staff_return_phone entirely - exactly what broke live sales after
-- part 6a shipped, fixed separately in part 6b. This file drops the stale
-- overload and reloads PostgREST's schema cache itself, in the same run,
-- rather than repeating that incident and needing a part 6e hotfix.
-- ============================================================================

create or replace function staff_return_phone(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid,
  p_reason text, p_fault_parts text[], p_notes text,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer as $$
declare
  v_row phones%rowtype;
  v_faulty boolean;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_return_phone');
  if v_seen is not null then return; end if;

  perform staff_of_shop(p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select * into v_row from phones where id = p_phone_id and shop_id = p_shop_id for update;
  if v_row.id is null then raise exception 'This phone is no longer on the system.'; end if;
  if v_row.status <> 'sold' then raise exception 'This phone is not currently marked as sold.'; end if;

  v_faulty := (p_reason = 'Faulty');
  update phones set status = case when v_faulty then 'faulty' else 'in_stock' end,
    return_reason=p_reason, fault_parts=p_fault_parts, return_notes=p_notes,
    date_returned=p_local_date, returned_ts=now()
    where id = p_phone_id;

  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_staff, extra)
    values (p_shop_id, now(), 'returned', v_row.id, v_row.model, v_row.description, v_row.imei, p_staff_id,
      jsonb_build_object('reason', p_reason, 'faultParts', to_jsonb(p_fault_parts), 'notes', p_notes, 'toFaulty', v_faulty));

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

drop function if exists public.staff_return_phone(text, uuid, date, uuid, text, text[], text);

notify pgrst, 'reload schema';

-- VERIFY AFTER RUNNING (should show exactly one row)
--   select p.proname, pg_get_function_identity_arguments(p.oid) as signature
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'staff_return_phone';
-- Then confirm a real return in the app succeeds.

-- ============================================================================
-- Done. Verified with supabase-test.js (mock backend, not this database):
-- the same key called twice records exactly one return, and a genuinely new
-- key against the phone's new status still gets the real refusal - proving
-- this suppresses a repeated key specifically, not returns in general once a
-- phone is no longer sold. Next: staff_close_day, same shape.
-- ============================================================================
