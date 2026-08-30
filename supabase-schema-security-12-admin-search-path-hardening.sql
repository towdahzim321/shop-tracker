-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Security Part 12: SET search_path on the
-- remaining admin_* SECURITY DEFINER functions
-- ============================================================================
-- Closes a finding from the security audit: 19 of 39 SECURITY DEFINER
-- functions were missing SET search_path - every admin_* function except
-- admin_delete_expense, admin_reset_staff_pin and admin_set_staff_pin
-- (which already had it from earlier work). Confirmed live during the
-- audit that this has NO exploit path today - anon/authenticated/PUBLIC
-- hold no CREATE privilege on public or extensions (the only schemas in
-- the effective search path), so there is nowhere for a caller to plant a
-- shadow object right now. This closes the gap anyway, to match the
-- hardening already done everywhere else in this schema (security-5,
-- security-6, security-9) and to stop relying on a schema-ACL assumption
-- staying true forever.
--
-- BODY-ONLY CHANGE for all 19 - no signature changes, so plain CREATE OR
-- REPLACE, no DROP FUNCTION, no NOTIFY pgrst needed. Every body below is
-- byte-identical (aside from added whitespace formatting, which doesn't
-- change PL/pgSQL semantics) to what pg_get_functiondef returned live
-- immediately before writing this file, with exactly one line inserted:
-- `set search_path to 'public', 'pg_temp'` right after `security definer`.
-- ============================================================================

create or replace function public.admin_add_shop(p_name text)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_who text;
  v_base_id text;
  v_id text;
  v_suffix int := 0;
  v_next_order int;
begin
  perform require_admin(); v_who := admin_username();

  if p_name is null or trim(p_name) = '' then
    raise exception 'Shop name is required.';
  end if;
  if exists (select 1 from shops where lower(name) = lower(trim(p_name))) then
    raise exception 'A shop with this name already exists.';
  end if;

  v_base_id := lower(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '', 'g'));
  if v_base_id = '' then
    raise exception 'Shop name must contain at least one letter or number.';
  end if;
  v_id := v_base_id;
  while exists (select 1 from shops where id = v_id) loop
    v_suffix := v_suffix + 1;
    v_id := v_base_id || v_suffix::text;
  end loop;

  select coalesce(max(sort_order), 0) + 1 into v_next_order from shops;
  begin
    insert into shops (id, name, active, sort_order) values (v_id, trim(p_name), true, v_next_order);
  exception when unique_violation then
    raise exception 'A shop with this id already exists.';
  end;

  insert into ledger (id, shop_id, ts, type, by_admin, note)
  values (gen_random_uuid(), v_id, now(), 'shop_added', v_who, 'Added shop "'||trim(p_name)||'" ('||v_id||')');

  return v_id;
end; $function$;

create or replace function public.admin_cash_adjustment(p_shop_id text, p_date date, p_amount numeric, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text;
begin
  perform require_admin(); v_who := admin_username();
  update daily_logs set adjustments = coalesce(adjustments,'[]'::jsonb) || jsonb_build_array(
      jsonb_build_object('amount', p_amount, 'reason', p_reason, 'ts', extract(epoch from now())*1000, 'by', v_who))
    where shop_id=p_shop_id and date=p_date;
  if not found then raise exception 'No end of day log found for this date.'; end if;
  insert into ledger (shop_id, ts, type, price, by_admin, note)
    values (p_shop_id, now(), 'cash_adjustment', p_amount, v_who,
      'Cash adjustment on '||p_date||': '||p_amount||' - '||p_reason);
end; $function$;

create or replace function public.admin_close_shop(p_shop_id text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_name text; v_active boolean;
begin
  perform require_admin(); v_who := admin_username();

  select name, active into v_name, v_active from shops where id = p_shop_id;
  if v_name is null then
    raise exception 'Shop not found.';
  end if;
  if not v_active then
    raise exception 'Shop is already closed.';
  end if;

  update shops set active = false where id = p_shop_id;

  insert into ledger (id, shop_id, ts, type, by_admin, note)
  values (gen_random_uuid(), p_shop_id, now(), 'shop_closed', v_who, 'Closed shop "'||v_name||'"');
end; $function$;

create or replace function public.admin_confirm_cash(p_shop_id text, p_date date)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_cash numeric;
begin
  perform require_admin(); v_who := admin_username();
  update daily_logs set confirmed=true, confirmed_by=v_who, confirmed_at=now()
    where shop_id=p_shop_id and date=p_date returning cash into v_cash;
  if not found then raise exception 'No end of day log found for this date.'; end if;
  insert into ledger (shop_id, ts, type, by_admin, note)
    values (p_shop_id, now(), 'cash_confirmed', v_who, 'Confirmed cash seen for '||p_date||': '||v_cash);
end; $function$;

create or replace function public.admin_deactivate_staff(p_staff_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform require_admin();
  update staff set active=false where id=p_staff_id;
end; $function$;

create or replace function public.admin_delete_log(p_shop_id text, p_date date)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text;
begin
  perform require_admin(); v_who := admin_username();
  insert into ledger (shop_id, ts, type, by_admin, note)
    values (p_shop_id, now(), 'deleted_eod', v_who, 'End of day log for '||p_date||' deleted by admin');
  delete from daily_logs where shop_id = p_shop_id and date = p_date;
end; $function$;

create or replace function public.admin_delete_phone(p_phone_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row phones%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from phones where id = p_phone_id for update;
  if v_row.id is null then raise exception 'Phone not found.'; end if;
  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_admin, note)
    values (v_row.shop_id, now(), 'deleted', v_row.id, v_row.model, v_row.description, v_row.imei, v_who,
      'Stock entry deleted by admin');
  delete from phones where id = p_phone_id;
end; $function$;

create or replace function public.admin_hide_model(p_model_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_name text; v_key text; v_in_use int;
begin
  perform require_admin(); v_who := admin_username();

  select name, name_key into v_name, v_key from models where id = p_model_id;
  if v_name is null then
    raise exception 'Model not found.';
  end if;
  select count(*) into v_in_use from phones where model_key = v_key;
  if v_in_use > 0 then
    raise exception 'Cannot hide "%": % phone(s) still reference this model.', v_name, v_in_use;
  end if;

  update models set active = false where id = p_model_id;

  insert into model_audit (id, ts, action, model_id, by_admin, note)
  values (gen_random_uuid(), now(), 'model_hidden', p_model_id, v_who, 'Hid model "'||v_name||'" from the pick list');
end; $function$;

create or replace function public.admin_mark_repaired(p_phone_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row phones%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from phones where id = p_phone_id for update;
  if v_row.id is null then raise exception 'Phone not found.'; end if;
  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_admin, note, extra)
    values (v_row.shop_id, now(), 'repaired', v_row.id, v_row.model, v_row.description, v_row.imei, v_who,
      'Repaired, returned to sellable stock', jsonb_build_object('faultParts', to_jsonb(v_row.fault_parts)));
  update phones set status='in_stock', repaired_at=now(), repaired_by=v_who,
    sale_price=null, date_sold=null, sold_ts=null, sold_by=null, below_price=false, price_shortfall=0
    where id = p_phone_id;
end; $function$;

create or replace function public.admin_rename_model(p_model_id uuid, p_new_name text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_old_name text; v_new_key text;
begin
  perform require_admin(); v_who := admin_username();

  if p_new_name is null or trim(p_new_name) = '' then
    raise exception 'Model name is required.';
  end if;
  select name into v_old_name from models where id = p_model_id;
  if v_old_name is null then
    raise exception 'Model not found.';
  end if;
  v_new_key := clean_model_key(p_new_name);
  if exists (select 1 from models where name_key = v_new_key and id <> p_model_id) then
    raise exception 'Another model with this name already exists.';
  end if;

  update models set name = trim(p_new_name), name_key = v_new_key where id = p_model_id;

  insert into model_audit (id, ts, action, model_id, by_admin, note)
  values (gen_random_uuid(), now(), 'model_renamed', p_model_id, v_who, 'Renamed model "'||v_old_name||'" to "'||trim(p_new_name)||'"');
end; $function$;

create or replace function public.admin_rename_shop(p_shop_id text, p_new_name text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_old_name text;
begin
  perform require_admin(); v_who := admin_username();

  if p_new_name is null or trim(p_new_name) = '' then
    raise exception 'Shop name is required.';
  end if;
  select name into v_old_name from shops where id = p_shop_id;
  if v_old_name is null then
    raise exception 'Shop not found.';
  end if;
  if exists (select 1 from shops where lower(name) = lower(trim(p_new_name)) and id <> p_shop_id) then
    raise exception 'A shop with this name already exists.';
  end if;

  update shops set name = trim(p_new_name) where id = p_shop_id;

  insert into ledger (id, shop_id, ts, type, by_admin, note)
  values (gen_random_uuid(), p_shop_id, now(), 'shop_renamed', v_who, 'Renamed shop "'||v_old_name||'" to "'||trim(p_new_name)||'"');
end; $function$;

create or replace function public.admin_reopen_day(p_shop_id text, p_date date)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_row business_days%rowtype; v_was_closed boolean; v_eod_exists boolean;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from business_days where shop_id=p_shop_id and date=p_date for update;
  v_was_closed := (v_row.id is not null and v_row.status='closed');
  select exists(select 1 from daily_logs where shop_id=p_shop_id and date=p_date) into v_eod_exists;

  insert into business_days (shop_id, date, status, opened_by, opened_at, closed_by, closed_at)
    values (p_shop_id, p_date, 'open', v_who, now(), null, null)
    on conflict (shop_id, date) do update set
      status='open', opened_by=v_who, opened_at=now(), closed_by=null, closed_at=null,
      reopen_count = business_days.reopen_count + (case when v_was_closed and v_eod_exists then 1 else 0 end),
      last_reopen_by = case when v_was_closed and v_eod_exists then v_who else business_days.last_reopen_by end,
      last_reopen_at = case when v_was_closed and v_eod_exists then now() else business_days.last_reopen_at end;

  if v_was_closed and v_eod_exists then
    insert into ledger (shop_id, ts, type, by_admin, note)
      values (p_shop_id, now(), 'reopen', v_who, 'Day '||p_date||' reopened after end of day was submitted');
  end if;
end; $function$;

create or replace function public.admin_set_model_brand(p_model_id uuid, p_brand text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_name text; v_brand text;
begin
  perform require_admin(); v_who := admin_username();

  select name into v_name from models where id = p_model_id;
  if v_name is null then
    raise exception 'Model not found.';
  end if;
  v_brand := nullif(trim(coalesce(p_brand, '')), '');
  update models set brand = v_brand where id = p_model_id;

  insert into model_audit (id, ts, action, model_id, by_admin, note)
  values (gen_random_uuid(), now(), 'model_brand_set', p_model_id, v_who, 'Set brand for "'||v_name||'" to '||coalesce(v_brand, '(none)'));
end; $function$;

create or replace function public.admin_set_pricing_batch(p_shop_id text, p_batch_id text, p_cost numeric, p_list numeric)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_who text; v_count int; v_model text;
begin
  perform require_admin(); v_who := admin_username();
  update phones set cost_price=p_cost, list_price=p_list,
      below_price = case when status='sold' and sale_price is not null and sale_price < p_list then true else false end,
      price_shortfall = case when status='sold' and sale_price is not null and sale_price < p_list
                              then round((p_list - sale_price)::numeric,2) else 0 end
    where shop_id=p_shop_id and batch_id=p_batch_id;
  get diagnostics v_count = row_count;
  select model into v_model from phones where shop_id=p_shop_id and batch_id=p_batch_id limit 1;
  insert into ledger (shop_id, ts, type, model, by_admin, note, extra)
    values (p_shop_id, now(), 'price_set', v_model, v_who,
      'Prices set for '||v_count||' phone(s): Dubai '||p_cost||' / Zim '||p_list,
      jsonb_build_object('batchId', p_batch_id));
  return v_count;
end; $function$;

create or replace function public.admin_undo_return(p_phone_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row phones%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from phones where id = p_phone_id for update;
  if v_row.id is null then raise exception 'Phone not found.'; end if;
  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, by_admin, note, extra)
    values (v_row.shop_id, now(), 'undo_return', v_row.id, v_row.model, v_row.description, v_row.imei, v_who,
      'Return undone by admin', jsonb_build_object('reason', v_row.return_reason));
  update phones set status='sold', return_reason=null, date_returned=null, returned_ts=null,
    fault_parts=null, return_notes=null where id = p_phone_id;
end; $function$;

create or replace function public.admin_undo_sale(p_phone_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row phones%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from phones where id = p_phone_id for update;
  if v_row.id is null then raise exception 'Phone not found.'; end if;
  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, price, by_admin, note)
    values (v_row.shop_id, now(), 'undo_sale', v_row.id, v_row.model, v_row.description, v_row.imei, v_row.sale_price, v_who,
      'Sale undone by admin (was sold on '||coalesce(v_row.date_sold::text,'-')||')');
  update phones set status='in_stock', sale_price=null, sold_by=null, date_sold=null, sold_ts=null,
    below_price=false, price_shortfall=0 where id = p_phone_id;
end; $function$;

create or replace function public.admin_username()
returns text
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce((select username from admins where user_id = auth.uid()), 'admin');
$function$;

create or replace function public.admin_wipe_shop_data(p_shop_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_who text;
  v_phones int; v_ledger int; v_logs int; v_days int;
begin
  perform require_admin(); v_who := admin_username();

  select count(*) into v_phones from phones where shop_id = p_shop_id;
  select count(*) into v_ledger from ledger where shop_id = p_shop_id;
  select count(*) into v_logs from daily_logs where shop_id = p_shop_id;
  select count(*) into v_days from business_days where shop_id = p_shop_id;

  delete from phones where shop_id = p_shop_id;
  delete from ledger where shop_id = p_shop_id;
  delete from daily_logs where shop_id = p_shop_id;
  delete from business_days where shop_id = p_shop_id;

  insert into shop_resets (shop_id, wiped_by, phones_removed, ledger_removed, daily_logs_removed, business_days_removed)
    values (p_shop_id, v_who, v_phones, v_ledger, v_logs, v_days);

  return jsonb_build_object('phones', v_phones, 'ledger', v_ledger, 'dailyLogs', v_logs, 'businessDays', v_days);
end; $function$;

create or replace function public.admin_write_off(p_phone_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_row phones%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();
  select * into v_row from phones where id = p_phone_id for update;
  if v_row.id is null then raise exception 'Phone not found.'; end if;
  insert into ledger (shop_id, ts, type, phone_id, model, description, imei, price, by_admin, note, extra)
    values (v_row.shop_id, now(), 'written_off', v_row.id, v_row.model, v_row.description, v_row.imei, v_row.cost_price, v_who,
      'Written off as a loss', jsonb_build_object('faultParts', to_jsonb(v_row.fault_parts)));
  update phones set status='written_off', written_off_at=now(), written_off_by=v_who, date_written_off=current_date
    where id = p_phone_id;
end; $function$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================
select p.proname, p.proconfig
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'admin_add_shop','admin_cash_adjustment','admin_close_shop','admin_confirm_cash',
  'admin_deactivate_staff','admin_delete_log','admin_delete_phone','admin_hide_model',
  'admin_mark_repaired','admin_rename_model','admin_rename_shop','admin_reopen_day',
  'admin_set_model_brand','admin_set_pricing_batch','admin_undo_return','admin_undo_sale',
  'admin_username','admin_wipe_shop_data','admin_write_off'
)
order by p.proname;
-- Expect: all 19 now show {"search_path=public, pg_temp"}.

-- ============================================================================
-- APPLY: staging first, then production. Per AGENTS.md's CRLF note, pipe
-- through stdin:
--   cat supabase-schema-security-12-admin-search-path-hardening.sql | psql "$DATABASE_URL_STAGING" -f -
--   cat supabase-schema-security-12-admin-search-path-hardening.sql | psql "$DATABASE_URL" -f -
-- Verify by diffing each function's pg_get_functiondef output against the
-- pre-migration capture from the audit - the SET search_path line should
-- be the only delta. No behavioural test needed (no logic changed), and
-- none of these can be exercised through PostgREST without a real admin
-- Auth session anyway.
-- ============================================================================
