-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Part 9: returns rework, Stage 3
-- (staff_return_phone gains four outcomes: return, swap, swap_topup, refund)
-- ============================================================================
-- SIGNATURE CHANGE. staff_return_phone gains four new trailing parameters:
-- p_outcome text default 'return', p_replacement_phone_id uuid default
-- null, p_topup_amount numeric default null, p_refund_amount numeric
-- default null. DROP FUNCTION on the exact old (Stage 1) signature, then
-- CREATE, then NOTIFY pgrst - matching the incantation already used for
-- security-8's staff RPC session-check migration. The defaults mean the
-- old call shape (no new params sent) reproduces exactly today's plain
-- return - p_outcome resolves to 'return', every new branch below is
-- skipped.
--
-- WHAT CHANGED
-- Everything through the phone-A lock/validate/clear and the 'returned'
-- ledger insert is the same as Stage 1's body. New:
--   1. Parameter-shape validation, before any lock is taken: p_outcome
--      must be one of 'return'/'swap'/'swap_topup'/'refund';
--      p_replacement_phone_id required iff swap/swap_topup, forbidden
--      otherwise; p_topup_amount required (>=0) iff swap_topup, forbidden
--      otherwise; p_refund_amount required (>0) iff refund, forbidden
--      otherwise.
--   2. Refund bound: p_refund_amount > coalesce(v_row.sale_price, 0)
--      raises. v_row is the phone-A row already locked via `select ...
--      for update` before this function's own six-column clear touches
--      it, so v_row.sale_price is the real original amount, no extra
--      bookkeeping needed. The coalesce matters: without it a null
--      sale_price makes the comparison evaluate to NULL (falsy in a
--      plpgsql `if`), silently letting an unbounded refund through.
--   3. Replacement lock (swap/swap_topup only): `select ... for update`
--      on p_replacement_phone_id, in the SAME transaction as phone A's
--      lock, both held before either row is written. Must exist, be
--      shop_id-matched, be status='in_stock', not be the same row as
--      phone A (defensive - the status checks alone would already catch
--      this via a slightly less clear error, this gives a direct one),
--      and have a non-null list_price (the next step assumes one exists).
--   4. Replacement update (swap/swap_topup only): status='sold',
--      sale_price = its OWN list_price (not the original amount - this
--      is what keeps per-phone margin accurate and avoids a false
--      below_price flag on a phone that's genuinely selling at list),
--      sold_by/date_sold/sold_ts set, below_price=false/price_shortfall=0
--      set outright rather than computed - correct by construction, since
--      sale_price=list_price here can never be "below list".
--   5. Ledger inserts beyond the existing 'returned' row for phone A
--      (which gains extra.outcome and, when applicable,
--      extra.linkedPhoneId/extra.refundAmount):
--        'swap_out'    - the replacement, swap/swap_topup only,
--                        price=list_price, extra.linkedPhoneId=phone A.
--        'swap_topup'  - swap_topup only, and only when p_topup_amount>0
--                        (a zero top-up is just an even swap, no row) -
--                        price=p_topup_amount, phone_id=the replacement,
--                        extra.linkedPhoneId=phone A.
--        'refund'      - refund only - price=p_refund_amount,
--                        phone_id=phone A.
-- ============================================================================

drop function staff_return_phone(text, uuid, date, uuid, text, text[], text, uuid, uuid);

create function staff_return_phone(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid,
  p_reason text, p_fault_parts text[], p_notes text,
  p_idempotency_key uuid default null, p_session_token uuid default null,
  p_outcome text default 'return', p_replacement_phone_id uuid default null,
  p_topup_amount numeric default null, p_refund_amount numeric default null
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row phones%rowtype;
  v_replacement phones%rowtype;
  v_faulty boolean;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_return_phone');
  if v_seen is not null then return; end if;

  if p_outcome not in ('return', 'swap', 'swap_topup', 'refund') then
    raise exception 'Unknown return outcome.';
  end if;

  if p_outcome in ('swap', 'swap_topup') then
    if p_replacement_phone_id is null then
      raise exception 'Pick a replacement phone for a swap.';
    end if;
  elsif p_replacement_phone_id is not null then
    raise exception 'This outcome does not take a replacement phone.';
  end if;

  if p_outcome = 'swap_topup' then
    if p_topup_amount is null or p_topup_amount < 0 then
      raise exception 'Enter a top-up amount of zero or more.';
    end if;
  elsif p_topup_amount is not null then
    raise exception 'This outcome does not take a top-up amount.';
  end if;

  if p_outcome = 'refund' then
    if p_refund_amount is null or p_refund_amount <= 0 then
      raise exception 'Enter a refund amount greater than zero.';
    end if;
  elsif p_refund_amount is not null then
    raise exception 'This outcome does not take a refund amount.';
  end if;

  perform require_staff_session(p_session_token, p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select * into v_row from phones where id = p_phone_id and shop_id = p_shop_id for update;
  if v_row.id is null then raise exception 'This phone is no longer on the system.'; end if;
  if v_row.status <> 'sold' then raise exception 'This phone is not currently marked as sold.'; end if;

  if p_outcome = 'refund' and p_refund_amount > coalesce(v_row.sale_price, 0) then
    raise exception 'Refund cannot exceed the original sale price.';
  end if;

  if p_outcome in ('swap', 'swap_topup') then
    select * into v_replacement from phones where id = p_replacement_phone_id and shop_id = p_shop_id for update;
    if v_replacement.id is null then raise exception 'Replacement phone is no longer on the system.'; end if;
    if v_replacement.id = v_row.id then raise exception 'Replacement phone must be different from the phone being returned.'; end if;
    if v_replacement.status <> 'in_stock' then raise exception 'Replacement phone is not available.'; end if;
    if v_replacement.list_price is null then raise exception 'Replacement phone has no list price set.'; end if;
  end if;

  v_faulty := (p_reason = 'Faulty');
  update phones set status = case when v_faulty then 'faulty' else 'in_stock' end,
    return_reason=p_reason, fault_parts=p_fault_parts, return_notes=p_notes,
    date_returned=p_local_date, returned_ts=now(),
    sale_price=null, sold_by=null, date_sold=null, sold_ts=null,
    below_price=false, price_shortfall=0
    where id = p_phone_id;

  if p_outcome in ('swap', 'swap_topup') then
    update phones set status='sold', sale_price=v_replacement.list_price, sold_by=p_staff_id,
      date_sold=p_local_date, sold_ts=now(), below_price=false, price_shortfall=0
      where id = v_replacement.id;
  end if;

  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_staff, extra)
    values (p_shop_id, now(), 'returned', v_row.id, v_row.model, v_row.description, v_row.imei, p_staff_id,
      jsonb_build_object(
        'reason', p_reason, 'faultParts', to_jsonb(p_fault_parts), 'notes', p_notes, 'toFaulty', v_faulty,
        'outcome', p_outcome,
        'linkedPhoneId', case when p_outcome in ('swap', 'swap_topup') then p_replacement_phone_id else null end,
        'refundAmount', case when p_outcome = 'refund' then p_refund_amount else null end
      ));

  if p_outcome in ('swap', 'swap_topup') then
    insert into ledger (shop_id, ts, type, phone_id, model, description, imei, price, by_staff, extra)
      values (p_shop_id, now(), 'swap_out', v_replacement.id, v_replacement.model, v_replacement.description, v_replacement.imei, v_replacement.list_price, p_staff_id,
        jsonb_build_object('linkedPhoneId', v_row.id));
  end if;

  if p_outcome = 'swap_topup' and p_topup_amount > 0 then
    insert into ledger (shop_id, ts, type, phone_id, price, by_staff, extra)
      values (p_shop_id, now(), 'swap_topup', v_replacement.id, p_topup_amount, p_staff_id,
        jsonb_build_object('linkedPhoneId', v_row.id));
  end if;

  if p_outcome = 'refund' then
    insert into ledger (shop_id, ts, type, phone_id, price, by_staff)
      values (p_shop_id, now(), 'refund', v_row.id, p_refund_amount, p_staff_id);
  end if;

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end;
$$;

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select pg_get_function_identity_arguments(oid) as args
from pg_proc where proname = 'staff_return_phone';

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's corrected CRLF
-- note, pipe through stdin:
--   cat supabase-schema-part9-returns-stage3.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-part9-returns-stage3.sql | psql "$DATABASE_URL" -f -
-- ============================================================================
