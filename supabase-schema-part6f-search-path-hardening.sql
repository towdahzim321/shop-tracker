-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6f: search_path hardening
-- Phase 4a (plumbing) — step 5 (closes the gap flagged in the post-deploy
-- read-only production verification: 4 of the 6 idempotent staff functions
-- had SET search_path, staff_sell_phone/staff_return_phone did not)
-- ============================================================================
-- Additive only. CREATE OR REPLACE is correct here, not DROP+CREATE - the
-- parameter list of both functions is unchanged (still ...,
-- p_idempotency_key uuid DEFAULT NULL::uuid as the last parameter, verified
-- live via pg_get_functiondef immediately before writing this file). Only
-- the function's own SET search_path configuration is being added; nothing
-- about the callable signature changes, so the function-signature-change
-- rule (DROP FUNCTION + CREATE + NOTIFY pgrst) does not apply, and no
-- schema-cache reload is needed - PostgREST's function cache is keyed on
-- name+argument types, not on a function's internal search_path setting.
--
-- WHY THIS GAP EXISTED
-- staff_sell_phone (part 6a) and staff_return_phone (part 6d) were the
-- first two functions converted to idempotent, written before this session
-- started hardening search_path on the functions it touched. Parts 6c
-- (idempotency_begin/idempotency_finish) and 6e (staff_receive_stock,
-- staff_submit_eod, staff_open_day, staff_close_day) all got
-- SET search_path TO 'public', 'pg_temp' along the way. These two were
-- simply missed at the time, not skipped on purpose - confirmed by
-- re-reading part 6a/6d's own file contents, neither ever set it.
--
-- CRYPT()/GEN_SALT() CHECK (done live, immediately before writing this
-- file, not assumed)
-- Re-pulled both functions' current live bodies via pg_get_functiondef and
-- grepped for crypt(/gen_salt( - zero matches in either. Both functions
-- only touch phones/ledger and call idempotency_begin/idempotency_finish/
-- staff_of_shop/require_day_open - no password hashing, no `extensions`
-- schema dependency. 'public', 'pg_temp' is the complete, correct path for
-- both, matching the other four idempotent functions exactly - not
-- 'public', 'extensions', 'pg_temp' (that pattern belongs to the PIN
-- functions - admin_set_staff_pin, admin_reset_staff_pin, staff_login -
-- which do call crypt()/gen_salt() and genuinely need `extensions` on the
-- path; these two don't).
--
-- WHAT CHANGED, PER FUNCTION
-- Nothing in either function's body - every statement, same order, same
-- text as currently live (verified above). The only addition is the
-- `set search_path to 'public', 'pg_temp'` clause on the function
-- declaration itself, so both idempotency_begin's own internal lookups and
-- everything these two functions call (phones, ledger, staff_of_shop,
-- require_day_open, idempotency_begin, idempotency_finish) resolve from a
-- fixed, non-hijackable path instead of whatever search_path the calling
-- session happens to have - the same protection the other four staff
-- functions already have.
-- ============================================================================

create or replace function staff_sell_phone(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid, p_price numeric,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
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

create or replace function staff_return_phone(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid,
  p_reason text, p_fault_parts text[], p_notes text,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
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

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- search_path for all six idempotent staff functions - all six should now
-- read the same: {"search_path=public, pg_temp"}
-- ============================================================================
select
  p.proname as function_name,
  p.proconfig as search_path_config,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_sell_phone','staff_return_phone','staff_receive_stock','staff_submit_eod','staff_open_day','staff_close_day')
order by p.proname;

-- ============================================================================
-- Not run yet. Next: apply this file with psql against $DATABASE_URL, then
-- run the verification query above and report the actual output.
-- ============================================================================
