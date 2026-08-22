-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 5b: phones_staff_view gains model_key
-- ============================================================================
-- Run this AFTER part 5. Part 5 has already run against the live database
-- and must not be edited - this is a separate, additive file.
--
-- WHY THIS EXISTS
-- Part 5 changed the phone-uniqueness rule from "IMEI alone" to
-- "IMEI + model" and taught staff_receive_stock to enforce it server-side.
-- But staff never talk to `phones` directly - they read phones_staff_view,
-- and that view was never updated to carry the new model_key column. So the
-- client's own duplicate check (which is supposed to warn staff immediately,
-- before they even try to save) had no model_key to compare against and
-- silently fell back to comparing bare IMEI - disagreeing with the server it
-- exists to give a preview of. Confirmed against the live column list:
--   id, shop_id, imei, model, description, batch_id, status, date_received,
--   received_ts, received_by, sale_price, sold_by, date_sold, sold_ts,
--   below_price, price_shortfall, return_reason, fault_parts, return_notes,
--   date_returned, returned_ts, repaired_at, repaired_by, written_off_at,
--   written_off_by, date_written_off, list_price
-- - 27 columns, no model_key, no cost_price (as intended - staff must never
-- see cost price).
--
-- SCOPE — READ THIS BEFORE RUNNING
-- Touches exactly one object: phones_staff_view. No table, no data, no other
-- view, no function, no policy, no grant. Nothing is deleted.
--
-- WHAT THIS CHANGES
-- create or replace view phones_staff_view, keeping all 27 existing columns
-- in exactly the same name, type and position, with model_key appended as
-- column 28. CREATE OR REPLACE VIEW only allows new columns at the end of
-- the list - reordering or changing an existing column's name/type would
-- make the replace fail outright (not silently corrupt anything), so the
-- column list below is copied in the exact order given, unchanged, with only
-- one addition at the tail.
--
-- WHAT THIS LEAVES ALONE
-- CREATE OR REPLACE VIEW preserves the view's OID, so its existing grants
-- (anon/authenticated SELECT) and ownership carry over automatically -
-- nothing here touches GRANT, REVOKE, or ALTER VIEW ... OWNER TO. The live
-- view also has no explicit security_invoker setting (confirmed via the
-- schema dump: no WITH clause on its CREATE VIEW), so it already runs with
-- the view owner's privileges, bypassing RLS on the underlying `phones`
-- table the same way every other staff-facing view in this schema does -
-- this file doesn't add a security_invoker setting either, so that behaviour
-- is unchanged. `phones` itself isn't touched - no row is added, changed, or
-- removed.
--
-- ledger_staff_view — CHECKED, DOES NOT NEED THE SAME FIX
-- Its `model` column is used by the client purely for display text (activity
-- feed rows, transaction labels) and event-labelling - never compared or
-- grouped for identity. Anywhere the client needs to tie a ledger row back to
-- a specific phone, it already does so via phone_id, and can get that
-- phone's model_key from phones_staff_view through that same id. Adding
-- model_key to ledger_staff_view would duplicate data without fixing
-- anything real, so left alone.
--
-- VERIFY AFTER RUNNING (all three should be true)
--   1) select model_key from phones_staff_view limit 1;
--      -- no error; a real value comes back for any row that has a model
--   2) select column_name from information_schema.columns
--        where table_name = 'phones_staff_view' order by ordinal_position;
--      -- cost_price must NOT be in this list; model_key should be last
--   3) select grantee, privilege_type from information_schema.role_table_grants
--        where table_name = 'phones_staff_view';
--      -- anon and authenticated should still show SELECT, same as before
--         this file ran
-- ============================================================================

create or replace view phones_staff_view as
select
  id,
  shop_id,
  imei,
  model,
  description,
  batch_id,
  status,
  date_received,
  received_ts,
  received_by,
  sale_price,
  sold_by,
  date_sold,
  sold_ts,
  below_price,
  price_shortfall,
  return_reason,
  fault_parts,
  return_notes,
  date_returned,
  returned_ts,
  repaired_at,
  repaired_by,
  written_off_at,
  written_off_by,
  date_written_off,
  list_price,
  model_key
from phones;

-- ============================================================================
-- Done. Run the three verification queries above before treating this as
-- confirmed - a view that "ran without error" is not the same as one that
-- still grants anon SELECT and still hides cost_price.
-- ============================================================================
