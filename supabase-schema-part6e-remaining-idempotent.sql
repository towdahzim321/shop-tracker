-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 6e: remaining four, idempotent
-- Phase 4a (plumbing) — step 4 (staff_sell_phone was step 2/part 6a,
-- staff_return_phone was step 3/part 6d)
-- ============================================================================
-- Run this AFTER part 6 (idempotency foundation), 6a, 6b, 6c, and 6d.
--
-- PRE-FLIGHT (run and confirmed live, this session, before writing this file)
-- Grouped pg_proc by (proname, pronargs) for all six staff_* functions.
-- Every one of the six showed overload_count = 1 - no stray overload from
-- an earlier half-applied migration anywhere in this set. Safe to proceed.
-- Also confirmed live: pg_default_acl for schema public, role postgres,
-- objtype 'f' grants EXECUTE to anon/authenticated directly - so a function
-- CREATEd fresh (not CREATE OR REPLACE) by postgres in this schema picks up
-- the same EXECUTE grants automatically, without a separate GRANT statement
-- here. Verification block at the bottom confirms this actually held.
--
-- WHY THIS ONE IS A DROP+CREATE, NOT CREATE OR REPLACE (unlike 6a/6d)
-- Adding p_idempotency_key changes each of these four signatures, same as
-- sell_phone/return_phone did. 6a used create-or-replace first and cleaned
-- up the resulting duplicate overload afterward in 6b, live, as a hotfix.
-- Not repeating that here: each function below is DROP FUNCTION on the
-- exact old signature, then CREATE FUNCTION (not "or replace") of the new
-- one, so there is never a moment where two overloads of the same staff_*
-- function coexist and PostgREST has to guess between them.
--
-- WHAT CHANGED, PER FUNCTION (verified against this session's live
-- pg_get_functiondef dump, not reconstructed)
-- All four: add p_idempotency_key uuid default null as the new final
-- parameter (default null keeps every existing caller, including today's
-- deployed client, working unchanged); add idempotency_begin(...) as the
-- very first statement in the body, before staff_of_shop, before
-- require_day_open, before anything else; add SET search_path TO 'public',
-- 'pg_temp' (matching idempotency_begin's own setting - these weren't
-- search_path-hardened before and are being touched anyway); everything
-- else in each body is untouched, same order, same text.
--
-- staff_receive_stock is the one non-void return in this batch (returns
-- integer). idempotency_finish stores the real count via to_jsonb(v_count),
-- not 'true'::jsonb, and a replayed call recovers it with
-- (v_seen #>> '{}')::integer instead of falling through to a bare return -
-- so a retried receive-stock call hands the caller back the same count it
-- got the first time, not NULL.
--
-- staff_submit_eod, staff_open_day both already have ON CONFLICT (shop_id,
-- date) DO UPDATE, which makes the row itself idempotent - but not the
-- side effects layered on top (resubmitted counter, previous_counts array,
-- reopen_count, the reopen ledger row) - those would still increment/fire
-- again on a bare network retry without the key. The idempotency wrapper
-- closes that gap the same way it does for sell/return.
--
-- staff_close_day already raises 'Today''s business day is not open.' when
-- retried after its own prior success (the day is now closed, not open) -
-- same retry-visible-as-refusal shape as sell_phone/return_phone had before
-- their conversion. idempotency_finish only runs after the update actually
-- finds a row, so a genuine failure (day never opened) still surfaces the
-- real exception and never gets cached as a success.
-- ============================================================================

drop function if exists public.staff_receive_stock(text, uuid, date, jsonb);

create function staff_receive_stock(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_items jsonb,
  p_idempotency_key uuid default null
)
returns integer
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_item jsonb;
  v_imei text;
  v_batch text;
  v_model text;
  v_desc text;
  v_model_key text;
  v_phone_id uuid;
  v_count int := 0;
  v_dupes text[];
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_receive_stock');
  if v_seen is not null then return (v_seen #>> '{}')::integer; end if;

  perform staff_of_shop(p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select array_agg(x.imei || ' (' || x.model || ')') into v_dupes
  from (
    select jsonb_array_elements_text(v.imeis) as imei, v.model as model
    from jsonb_to_recordset(p_items) as v(imeis jsonb, model text)
  ) x
  where exists (
    select 1 from phones p
    where p.imei = x.imei and p.model_key = clean_model_key(x.model)
  );
  if v_dupes is not null and array_length(v_dupes,1) > 0 then
    raise exception 'Already recorded: %', array_to_string(v_dupes, ', ');
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_batch := 'b' || replace(gen_random_uuid()::text, '-', '');
    v_model := v_item->>'model';
    v_desc := nullif(v_item->>'description', '');
    v_model_key := clean_model_key(v_model);

    insert into models (name, name_key, active, created_by)
      values (trim(v_model), v_model_key, true, p_staff_id)
      on conflict (name_key) do nothing;

    for v_imei in select jsonb_array_elements_text(v_item->'imeis') loop
      insert into phones (shop_id, imei, model, description, batch_id, status, date_received, received_ts, received_by)
        values (p_shop_id, v_imei, v_model, v_desc, v_batch, 'in_stock', p_local_date, now(), p_staff_id)
        returning id into v_phone_id;
      insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_staff, extra)
        values (p_shop_id, now(), 'received', v_phone_id, v_model, v_desc, v_imei, p_staff_id, jsonb_build_object('batchId', v_batch));
      v_count := v_count + 1;
    end loop;
  end loop;

  perform idempotency_finish(p_idempotency_key, to_jsonb(v_count));
  return v_count;
end; $$;

drop function if exists public.staff_submit_eod(text, uuid, date, integer, integer, numeric);

create function staff_submit_eod(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_physical_count integer,
  p_faulty_count integer, p_cash numeric,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_who text;
  v_prev daily_logs%rowtype;
  v_resubmit boolean := false;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_submit_eod');
  if v_seen is not null then return; end if;

  v_who := staff_of_shop(p_staff_id, p_shop_id);
  perform require_day_open(p_shop_id, p_local_date);

  select * into v_prev from daily_logs where shop_id = p_shop_id and date = p_local_date for update;
  if v_prev.id is not null then v_resubmit := true; end if;

  insert into daily_logs (shop_id, date, physical_count, faulty_count, cash, submitted_by, submitted_at,
      confirmed, confirmed_by, confirmed_at, resubmitted, previous_counts, adjustments)
    values (p_shop_id, p_local_date, p_physical_count, p_faulty_count, p_cash, p_staff_id, now(),
      coalesce(v_prev.confirmed, false), v_prev.confirmed_by, v_prev.confirmed_at,
      coalesce(v_prev.resubmitted, 0) + (case when v_resubmit then 1 else 0 end),
      case when v_resubmit then coalesce(v_prev.previous_counts,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          'physicalCount', v_prev.physical_count, 'faultyCount', v_prev.faulty_count, 'cash', v_prev.cash,
          'submittedBy', (select name from staff where id = v_prev.submitted_by),
          'timestamp', extract(epoch from v_prev.submitted_at)*1000))
        else '[]'::jsonb end,
      coalesce(v_prev.adjustments, '[]'::jsonb))
    on conflict (shop_id, date) do update set
      physical_count = excluded.physical_count, faulty_count = excluded.faulty_count, cash = excluded.cash,
      submitted_by = excluded.submitted_by, submitted_at = excluded.submitted_at,
      resubmitted = excluded.resubmitted, previous_counts = excluded.previous_counts;

  insert into ledger (shop_id, ts, type, by_staff, note)
    values (p_shop_id, now(), 'eod', p_staff_id,
      'End of day: '||p_physical_count||' good, '||p_faulty_count||' faulty, '||p_cash||' cash'
        ||(case when v_resubmit then ' (replaced an earlier submission)' else '' end));

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

drop function if exists public.staff_open_day(text, uuid, date);

create function staff_open_day(
  p_shop_id text, p_staff_id uuid, p_local_date date,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_who text;
  v_row business_days%rowtype;
  v_was_closed boolean;
  v_eod_exists boolean;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_open_day');
  if v_seen is not null then return; end if;

  v_who := staff_of_shop(p_staff_id, p_shop_id);
  select * into v_row from business_days where shop_id = p_shop_id and date = p_local_date for update;
  v_was_closed := (v_row.id is not null and v_row.status = 'closed');
  select exists(select 1 from daily_logs where shop_id=p_shop_id and date=p_local_date) into v_eod_exists;

  insert into business_days (shop_id, date, status, opened_by, opened_at, closed_by, closed_at)
    values (p_shop_id, p_local_date, 'open', v_who, now(), null, null)
    on conflict (shop_id, date) do update set
      status='open', opened_by=v_who, opened_at=now(), closed_by=null, closed_at=null,
      reopen_count = business_days.reopen_count + (case when v_was_closed and v_eod_exists then 1 else 0 end),
      last_reopen_by = case when v_was_closed and v_eod_exists then v_who else business_days.last_reopen_by end,
      last_reopen_at = case when v_was_closed and v_eod_exists then now() else business_days.last_reopen_at end;

  if v_was_closed and v_eod_exists then
    insert into ledger (shop_id, ts, type, by_staff, note)
      values (p_shop_id, now(), 'reopen', p_staff_id, 'Day '||p_local_date||' reopened after end of day was submitted');
  end if;

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

drop function if exists public.staff_close_day(text, uuid, date);

create function staff_close_day(
  p_shop_id text, p_staff_id uuid, p_local_date date,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_who text;
  v_stock int;
  v_faulty int;
  v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_close_day');
  if v_seen is not null then return; end if;

  v_who := staff_of_shop(p_staff_id, p_shop_id);
  select count(*) into v_stock from phones where shop_id=p_shop_id and status='in_stock';
  select count(*) into v_faulty from phones where shop_id=p_shop_id and status='faulty';
  update business_days set status='closed', closed_by=v_who, closed_at=now(),
    closing_stock=v_stock, closing_faulty=v_faulty
    where shop_id=p_shop_id and date=p_local_date and status='open';
  if not found then raise exception 'Today''s business day is not open.'; end if;

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================

-- 1) New signatures, search_path, and live EXECUTE grants for all four
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as current_signature,
  p.proconfig as search_path_config,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_receive_stock','staff_submit_eod','staff_open_day','staff_close_day')
order by p.proname;

-- 2) Old signatures must all be gone (every column here must read NULL)
select
  to_regprocedure('public.staff_receive_stock(text, uuid, date, jsonb)') as old_receive_stock,
  to_regprocedure('public.staff_submit_eod(text, uuid, date, integer, integer, numeric)') as old_submit_eod,
  to_regprocedure('public.staff_open_day(text, uuid, date)') as old_open_day,
  to_regprocedure('public.staff_close_day(text, uuid, date)') as old_close_day;

-- 3) Total pg_proc row count per name, independent of the to_regprocedure
-- checks above - catches any stray overload the exact-signature checks in
-- (2) wouldn't, since each must show exactly 1.
select p.proname, count(*)
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_receive_stock','staff_submit_eod','staff_open_day','staff_close_day')
group by p.proname
order by p.proname;

-- ============================================================================
-- Not run yet. Next: apply this file with psql against $DATABASE_URL, then
-- run the verification block above and report the actual output before any
-- client-side cutover to sending p_idempotency_key on these four calls.
-- ============================================================================
