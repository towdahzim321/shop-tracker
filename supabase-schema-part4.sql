-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 4: reset a shop's data
-- ============================================================================
-- Run this after part 1, 2 and 3. Safe to re-run.
--
-- Adds ONE new admin-only action: wipe every stock/sales/day record for a
-- single shop, so you can clear out test/demo entries before showing the
-- app to a client - and do it again any time in future (e.g. starting a new
-- shop, or a clean slate after more testing) without needing me involved.
--
-- What it deletes for the chosen shop: every phone (stock/sold/faulty/
-- written off), the full ledger history, every end-of-day log, and every
-- business-day open/close record.
-- What it leaves alone: staff logins/PINs, admin accounts, the other two
-- shops, and the low-stock setting. This is a per-shop reset, not a factory
-- reset of the whole app.
--
-- A small separate table (not wiped by this action) keeps a permanent
-- record of who cleared a shop and when, so that history survives even if
-- the same shop gets reset again later.
--
-- This only ever runs for a signed-in admin (require_admin(), same guard as
-- every other admin_* function) - a staff device can never call this.
-- ============================================================================

create table if not exists shop_resets (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  wiped_by text not null,
  wiped_at timestamptz not null default now(),
  phones_removed int not null default 0,
  ledger_removed int not null default 0,
  daily_logs_removed int not null default 0,
  business_days_removed int not null default 0
);
alter table shop_resets enable row level security;
drop policy if exists shop_resets_admin_all on shop_resets;
create policy shop_resets_admin_all on shop_resets for all using (is_admin()) with check (is_admin());

create or replace function admin_wipe_shop_data(p_shop_id text)
returns jsonb
language plpgsql security definer as $$
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
end; $$;

-- ============================================================================
-- Done. Next: open the app, go to Settings, and you'll see a new "Danger
-- zone" section at the bottom for the shop you have selected in the Staff
-- tabs at the top of that screen.
-- ============================================================================
