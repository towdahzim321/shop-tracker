-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Rollback for Security Part 8
-- ============================================================================
-- Reverts supabase-schema-security-8-staff-rpc-session-check.sql exactly:
-- drops the eight-parameter versions of all seven staff RPCs and
-- require_staff_session, recreates the seven RPCs with their original
-- seven-parameter signatures and bodies (trusting p_staff_id directly via
-- staff_of_shop, no session check) — byte-identical to what was live
-- immediately before security-8, pulled via pg_get_functiondef at that
-- time and reproduced here verbatim, not retyped from memory.
--
-- Does NOT touch staff_sessions or staff_login — those are security-7,
-- a separate, already-in-production migration this file has no opinion
-- on. Rolling back security-8 only undoes security-8.
--
-- Signature changes again (parameter count reverts), so this is DROP +
-- CREATE + NOTIFY, not CREATE OR REPLACE, same as the forward migration.
-- ============================================================================

drop function staff_close_day(text, uuid, date, uuid, uuid);
drop function staff_log_expense(text, uuid, date, text, numeric, text, uuid, uuid);
drop function staff_open_day(text, uuid, date, uuid, uuid);
drop function staff_receive_stock(text, uuid, date, jsonb, uuid, uuid);
drop function staff_return_phone(text, uuid, date, uuid, text, text[], text, uuid, uuid);
drop function staff_sell_phone(text, uuid, date, uuid, numeric, uuid, uuid);
drop function staff_submit_eod(text, uuid, date, integer, integer, numeric, uuid, uuid);
drop function require_staff_session(uuid, uuid, text);

-- ---------------------------------------------------------------------------

create function staff_close_day(p_shop_id text, p_staff_id uuid, p_local_date date, p_idempotency_key uuid default null)
returns void
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------

create function staff_log_expense(p_shop_id text, p_staff_id uuid, p_local_date date, p_category text, p_amount numeric, p_note text, p_idempotency_key uuid default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_seen jsonb;
begin
  v_seen := idempotency_begin(p_idempotency_key, 'staff_log_expense');
  if v_seen is not null then return; end if;

  perform staff_of_shop(p_staff_id, p_shop_id);

  if p_local_date < current_date - 1 or p_local_date > current_date + 1 then
    raise exception 'This date is too far from today to log an expense against. Check the date and try again.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter an amount greater than zero.';
  end if;

  if p_category <> all(array[
    'Transport','Airtime/data','Bank charges','Electricity (ZESA)','Stationery/packaging',
    'Cleaning','Repairs/maintenance','Staff refreshments','Security','Other'
  ]) then
    raise exception 'Unknown expense category.';
  end if;

  insert into expenses (shop_id, date, category, amount, note, staff_id)
    values (p_shop_id, p_local_date, p_category, p_amount, p_note, p_staff_id);

  insert into ledger (shop_id, ts, type, price, by_staff, extra)
    values (p_shop_id, now(), 'expense', p_amount, p_staff_id,
      jsonb_build_object('category', p_category, 'note', p_note));

  perform idempotency_finish(p_idempotency_key, 'true'::jsonb);
end; $$;

-- ---------------------------------------------------------------------------

create function staff_open_day(p_shop_id text, p_staff_id uuid, p_local_date date, p_idempotency_key uuid default null)
returns void
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------

create function staff_receive_stock(p_shop_id text, p_staff_id uuid, p_local_date date, p_items jsonb, p_idempotency_key uuid default null)
returns integer
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------

create function staff_return_phone(p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid, p_reason text, p_fault_parts text[], p_notes text, p_idempotency_key uuid default null)
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

-- ---------------------------------------------------------------------------

create function staff_sell_phone(p_shop_id text, p_staff_id uuid, p_local_date date, p_phone_id uuid, p_price numeric, p_idempotency_key uuid default null)
returns void
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------

create function staff_submit_eod(p_shop_id text, p_staff_id uuid, p_local_date date, p_physical_count integer, p_faulty_count integer, p_cash numeric, p_idempotency_key uuid default null)
returns void
language plpgsql
security definer
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

-- ---------------------------------------------------------------------------

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICATION (run after applying)
-- ============================================================================
select p.proname, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_close_day','staff_log_expense','staff_open_day',
    'staff_receive_stock','staff_return_phone','staff_sell_phone','staff_submit_eod')
order by p.proname;
-- Expect: no p_session_token in any argument list, and no row at all for
-- require_staff_session (it no longer exists).
