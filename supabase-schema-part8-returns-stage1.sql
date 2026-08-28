-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Part 8: returns rework, Stage 1
-- (six-column clear on staff_return_phone)
-- ============================================================================
-- BODY CHANGE ONLY. Same exact 8-parameter signature as today, including
-- p_session_token. CREATE OR REPLACE - no DROP FUNCTION, no NOTIFY pgrst.
-- PostgREST's function cache is keyed on name + argument types, neither of
-- which changes here, so no schema-cache reload is needed. Do not confuse
-- this with Stage 3 (the four-outcome swap/top-up/refund rework), which
-- DOES change the signature and DOES need DROP + CREATE + NOTIFY.
--
-- WHY THIS EXISTS
-- First real step of the returns rework (item (e) from the backlog).
-- staff_return_phone moves a sold phone to faulty/in_stock but has never
-- cleared its sale record - sale_price, sold_by, date_sold, sold_ts,
-- below_price, price_shortfall all stay exactly as they were at the moment
-- of sale. admin_undo_sale already clears all six of these on its own
-- reversal; this brings staff_return_phone in line with that existing
-- precedent, so a returned phone doesn't keep carrying a stale sale record
-- once it's back in stock or on the faulty shelf.
--
-- Checked before writing this file (not assumed): screenOwnerFaulty() used
-- to read phones.sale_price directly for its "Cost $X - sold for $Y" line
-- on the faulty shelf - that's the one place in the client this six-column
-- clear would have silently changed what the admin sees. Already fixed and
-- live in production (commit 31b012f): it now reads the amount from the
-- phone's own 'sold' ledger row instead, which a return never touches. So
-- this file is safe to ship without losing anything.
--
-- WHAT CHANGED
-- One addition to the existing `update phones set ...` statement - the same
-- six columns, same reset values, as admin_undo_sale. Every other statement
-- - idempotency_begin/require_staff_session/require_day_open in the same
-- order, the 'returned' ledger insert, idempotency_finish - is unchanged.
-- ============================================================================

create or replace function staff_return_phone(p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid, p_reason text, p_fault_parts text[], p_notes text, p_idempotency_key uuid default null, p_session_token uuid default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row phones%rowtype;
  v_faulty boolean;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_return_phone');
  if v_seen is not null then return; end if;

  perform require_staff_session(p_session_token, p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select * into v_row from phones where id = p_phone_id and shop_id = p_shop_id for update;
  if v_row.id is null then raise exception 'This phone is no longer on the system.'; end if;
  if v_row.status <> 'sold' then raise exception 'This phone is not currently marked as sold.'; end if;

  v_faulty := (p_reason = 'Faulty');
  update phones set status = case when v_faulty then 'faulty' else 'in_stock' end,
    return_reason=p_reason, fault_parts=p_fault_parts, return_notes=p_notes,
    date_returned=p_local_date, returned_ts=now(),
    sale_price=null, sold_by=null, date_sold=null, sold_ts=null,
    below_price=false, price_shortfall=0
    where id = p_phone_id;

  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_staff, extra)
    values (p_shop_id, now(), 'returned', v_row.id, v_row.model, v_row.description, v_row.imei, p_staff_id,
      jsonb_build_object('reason', p_reason, 'faultParts', to_jsonb(p_fault_parts), 'notes', p_notes, 'toFaulty', v_faulty));

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end;
$$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select p.proname, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_return_phone';

-- ============================================================================
-- APPLY: STAGING ONLY THIS PASS. Per AGENTS.md's corrected CRLF note, pipe
-- through stdin:
--   cat supabase-schema-part8-returns-stage1.sql | psql "$DATABASE_URL_STAGING" -f -
-- Do NOT run against $DATABASE_URL (production) this pass.
-- ============================================================================
