-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6a: staff_sell_phone, idempotent
-- Phase 4a (plumbing) — step 2: pilot conversion
-- ============================================================================
-- Run this AFTER part 6 (the idempotency foundation). Safe to re-run
-- (create or replace).
--
-- WHY THIS ONE FIRST
-- Simplest representative shape of the whole phase: single row read-modify-
-- write, single ledger insert, void return, and an existing status guard
-- that already makes a retry's SYMPTOM visible today (a genuine sale retried
-- after a network hang gets "This phone is no longer available for sale." -
-- true, but misleading, since it was THEIR OWN prior success that made it
-- true). Proving the pattern here in full before repeating it 19 more times.
--
-- WHAT CHANGED FROM THE LIVE FUNCTION (verified against
-- backups/schema.dump.sql - not reconstructed)
-- Exactly one addition: a p_idempotency_key parameter (default null, so
-- every existing caller - including the current deployed client, which sends
-- nothing - keeps working exactly as before), and the begin/finish calls
-- required to use it. The 4 existing statements in the body (staff_of_shop,
-- require_day_open, the two status checks, the update, the ledger insert)
-- are untouched, same order, same text.
--
-- idempotency_finish is the last statement on the only success path - there
-- is no early return between idempotency_begin and it, per the discipline in
-- part 6's header.
--
-- A seen key returns void with no error - correct for this function, since
-- void means the client only cares whether res.ok is true, not any specific
-- payload. Nothing here stores or replays a value, unlike the later
-- functions that return something the client displays.
-- ============================================================================

create or replace function staff_sell_phone(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid, p_price numeric,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer as $$
declare
  v_row phones%rowtype;
  v_below boolean := false;
  v_short numeric := 0;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_sell_phone');
  if v_seen is not null then return; end if;

  perform staff_of_shop(p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select * into v_row from phones where id = p_phone_id and shop_id = p_shop_id for update;
  if v_row.id is null then raise exception 'This phone is no longer on the system. Ask the owner to check.'; end if;
  if v_row.status <> 'in_stock' then raise exception 'This phone is no longer available for sale.'; end if;

  if v_row.list_price is not null and p_price < v_row.list_price then
    v_below := true;
    v_short := round((v_row.list_price - p_price)::numeric, 2);
  end if;

  update phones set status='sold', sale_price=p_price, sold_by=p_staff_id, date_sold=p_local_date,
    sold_ts=now(), below_price=v_below, price_shortfall=v_short
    where id = p_phone_id;

  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, price, by_staff, extra)
    values (p_shop_id, now(), 'sold', v_row.id, v_row.model, v_row.description, v_row.imei, p_price, p_staff_id,
      jsonb_build_object('belowPrice', v_below, 'shortfall', v_short));

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

-- ============================================================================
-- Done. Verified with supabase-test.js (mock backend, not this database):
-- the same key called twice records exactly one sale, and a genuinely new
-- key against the same now-sold phone still gets the real refusal - proving
-- this suppresses a repeated key specifically, not sales in general once a
-- phone is sold. Next: staff_return_phone and staff_close_day, same shape.
-- ============================================================================
