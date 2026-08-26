-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 7: expenses
-- Phase 5 (the "Phase 5 expenses" referenced in part 6's own header) — step 1,
-- additive schema only
-- ============================================================================
-- Run this on its own. Purely additive - one new table, three new functions.
-- Nothing that exists today changes behaviour. Client wiring is a separate,
-- later change - this file ships nothing staff or admin can reach yet.
--
-- WHY THIS EXISTS
-- Prerequisite for a future expected-cash variance check: stock already has
-- one (shopStats() compares log.physicalCount against systemStock client-
-- side), cash has none - daily_logs.cash is just whatever staff typed, never
-- checked against anything. Expenses is the other real, moving input that
-- check would need (money legitimately leaves the till during the day,
-- separately from admin's own post-hoc corrections in
-- daily_logs.adjustments). The variance calculation itself is explicitly NOT
-- part of this file - this only makes sure the data exists in a shape that
-- calculation could use.
--
-- WHY NOT admin_cash_adjustment
-- That function requires a daily_logs row for the exact shop+date to already
-- exist ("if not found then raise exception 'No end of day log found for
-- this date.'") and is admin-only. Expenses need to be logged by STAFF, by
-- design, and specifically have to work before that day's EOD - or even
-- before the day is opened at all (a bank-transport fare paid at 8am, before
-- staff_open_day has run) - which admin_cash_adjustment structurally cannot
-- do. Kept fully separate: expenses do not write into daily_logs.adjustments,
-- and cashNet() (log.cash + sum(adjustments)) is untouched by this file. A
-- future variance calculation reads daily_logs.cash and expenses as two
-- independent inputs, not one merged into the other.
--
-- WHY NO require_day_open
-- Checked live before writing this: require_day_open(p_shop_id, p_local_date)
-- does exactly one thing - raise unless business_days.status = 'open' for
-- that shop+date. It exists on the other six staff actions because they're
-- stock or cash-REPORTING mutations that need an open business_days row to
-- reconcile against. An expense doesn't mutate stock and isn't itself
-- reconciled against anything (yet) - it's an independent row keyed by
-- (shop_id, date), with no foreign key to business_days at all. Gating it on
-- day-open would force staff into a bad choice for exactly the case this
-- feature exists for: an expense paid before the day opens (or after it
-- closes) would have to be skipped, backdated once the day opens, or made to
-- open the day prematurely just to log a taxi fare. staff_of_shop's
-- staff-belongs-to-this-shop check is untouched and still runs regardless.
--
-- THE DATE-WINDOW GUARDRAIL, IN PLACE OF require_day_open
-- p_local_date must fall within [current_date - 1, current_date + 1] of the
-- SERVER's current_date (UTC, Supabase's default). This is deliberately a
-- 3-day window, not literally "today or yesterday" measured in UTC: Harare
-- is UTC+2, so for roughly the first two hours of each UTC day, a shop's
-- local calendar date is already one day AHEAD of the server's current_date.
-- A same-timezone-naive check of just [current_date - 1, current_date] would
-- incorrectly reject a real submission made from Harare in that window.
-- current_date + 1 absorbs exactly that skew; current_date - 1 covers the
-- "yesterday" case the spec asked for (e.g. logging an expense the next
-- morning for cash spent late the previous night). This is a sanity check
-- against fat-fingered/garbage dates, not a reconciliation boundary.
--
-- CATEGORY VALIDATION - RPC body, not a CHECK constraint
-- Checked live before writing this: phones.status and ledger.type have zero
-- CHECK constraints in this schema - the only CHECK constraint anywhere in
-- public is settings_singleton, unrelated. But that precedent works for
-- status/type specifically because those are NEVER client-supplied - every
-- staff_/admin_ function writes a hardcoded literal ('sold', 'returned',
-- etc.), so there's nothing to validate. category IS client-supplied (staff
-- picks one), so unlike status/type there is no other layer of defense at
-- all without an explicit check - "matching phones.status" here means "no
-- CHECK constraint," not "no validation." staff_log_expense below validates
-- p_category against the fixed list explicitly, same place client-side
-- validation already happens for RETURN_REASONS/FAULT_PARTS. Adding, renaming,
-- or retiring a category is therefore a pure application-layer change to
-- this one array plus the matching client-side constant - no migration, no
-- constraint swap, ever. The cost of a genuine rename is real regardless of
-- where the list lives: existing rows keep whatever string they were written
-- with unless a separate UPDATE explicitly changes them - that's a data
-- decision for whoever renames a category, not a schema one.
--
-- WHY NO admin-edit RPC
-- Nothing in this schema lets you edit a financial record in place -
-- admin_cash_adjustment only appends, admin_delete_phone only deletes with
-- an audit row first, an EOD "edit" is actually a full resubmission plus an
-- archived-previous-version record. admin_delete_expense follows the same
-- delete-with-audit shape as admin_delete_phone; the correction path for a
-- wrong entry is delete-then-relog, not an in-place edit.
--
-- RESUBMISSION / adjustments CARRY-FORWARD - not applicable here
-- previous_counts and the adjustments carry-forward in staff_submit_eod
-- exist specifically because those are jsonb blobs embedded ON the
-- daily_logs row, which staff_submit_eod's ON CONFLICT ... DO UPDATE fully
-- overwrites - without that carry-forward code a resubmission would silently
-- wipe them. expenses rows live in their own table keyed by (shop_id, date),
-- entirely independent of daily_logs' row lifecycle. Resubmitting EOD for a
-- day never touches expenses at all; they're just queried fresh by shop+date
-- whenever needed, regardless of how many times that day's EOD was
-- resubmitted. Nothing to carry forward because nothing gets overwritten.
--
-- ACCESS MODEL - verified against how phones/shop_resets/model_audit are
-- actually protected today, not assumed: table-level grants to anon/
-- authenticated are Supabase's default and are NOT revoked on any existing
-- table in this schema (confirmed live) - the real boundary is RLS. Every
-- admin-only table has RLS enabled plus one FOR ALL USING (is_admin())
-- policy; staff never touch the table directly, only through SECURITY
-- DEFINER functions, which run as the table owner and bypass RLS regardless.
-- expenses follows the identical shape: RLS enabled, one admin-all policy,
-- and staff_log_expense/staff_today_expenses/admin_delete_expense are the
-- only doors in. No REVOKE on the table itself - matches phones/shop_resets/
-- model_audit exactly, not the idempotency_keys/idempotency_begin pattern
-- (those are true internal-only helpers never meant to be called by any
-- client at all, which is why THEY get an explicit
-- revoke ... from public, anon, authenticated - the three functions below
-- are meant to be called directly by staff/admin clients, same as every
-- other staff_/admin_ function, so their default grants are left alone,
-- exactly like staff_sell_phone and admin_delete_phone are today.
-- ============================================================================

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null references shops(id),
  date date not null,
  category text not null,
  amount numeric not null,
  note text,
  staff_id uuid not null references staff(id),
  created_at timestamptz not null default now()
);

create index if not exists expenses_shop_date_idx on expenses (shop_id, date);

alter table expenses enable row level security;

create policy expenses_admin_all on expenses
  for all using (is_admin());

create or replace function staff_log_expense(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_category text, p_amount numeric, p_note text,
  p_idempotency_key uuid default null
)
returns void
language plpgsql security definer
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

-- Read-only, shaped exactly like staff_recent_daily_logs(p_shop_id) (RETURNS
-- SETOF <table>, no staff_id/staff_of_shop check - matches that function's
-- own trust model precisely: shop-scoped, not staff-identity-scoped). Takes
-- p_local_date explicitly rather than using current_date server-side, unlike
-- staff_recent_daily_logs' rolling 60-day window - a single day's total is
-- exactly the case where the client's own local date has to win over the
-- server's UTC idea of "today", for the same Harare/UTC skew reason the
-- date-window guardrail above exists.
create or replace function staff_today_expenses(p_shop_id text, p_local_date date)
returns setof expenses
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  return query
    select * from expenses
    where shop_id = p_shop_id and date = p_local_date
    order by created_at;
end; $$;

-- Same shape as admin_delete_phone: audit ledger row inserted BEFORE the
-- delete, snapshotting what's being removed, so the deletion itself is never
-- silent even though the row disappears.
create or replace function admin_delete_expense(p_expense_id uuid)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_row expenses%rowtype; v_who text;
begin
  perform require_admin(); v_who := admin_username();

  select * into v_row from expenses where id = p_expense_id for update;
  if v_row.id is null then raise exception 'Expense not found.'; end if;

  insert into ledger (shop_id, ts, type, price, by_admin, extra)
    values (v_row.shop_id, now(), 'deleted_expense', v_row.amount, v_who,
      jsonb_build_object('category', v_row.category, 'note', v_row.note, 'expenseDate', v_row.date));

  delete from expenses where id = p_expense_id;
end; $$;

-- ============================================================================
-- VERIFICATION (run after applying - actual live output, not a description)
-- ============================================================================

-- 1) Table shape
select column_name, data_type, is_nullable
from information_schema.columns
where table_name = 'expenses'
order by ordinal_position;

-- 2) Index present
select indexname from pg_indexes where tablename = 'expenses';

-- 3) RLS enabled + exactly the one admin-all policy
select relrowsecurity from pg_class where relname = 'expenses' and relnamespace = 'public'::regnamespace;
select policyname, roles, cmd, qual from pg_policies where tablename = 'expenses';

-- 4) All three functions exist, are SECURITY DEFINER, and have search_path pinned
select p.proname as function_name, p.prosecdef as security_definer, p.proconfig as search_path_config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_log_expense','staff_today_expenses','admin_delete_expense')
order by p.proname;

-- 5) Staff functions stay callable by anon/authenticated (Supabase's default,
--    matching every other staff_ function - staff never go through Supabase
--    Auth, so this is the door they use); admin function likewise left at
--    its default (matches admin_delete_phone's live grants) since the real
--    gate is require_admin() inside the function body, not the grant.
select 'staff_log_expense' as fn, 'anon' as role, has_function_privilege('anon', 'staff_log_expense(text,uuid,date,text,numeric,text,uuid)', 'EXECUTE') as can_execute
union all
select 'staff_log_expense', 'authenticated', has_function_privilege('authenticated', 'staff_log_expense(text,uuid,date,text,numeric,text,uuid)', 'EXECUTE')
union all
select 'staff_today_expenses', 'anon', has_function_privilege('anon', 'staff_today_expenses(text,date)', 'EXECUTE')
union all
select 'staff_today_expenses', 'authenticated', has_function_privilege('authenticated', 'staff_today_expenses(text,date)', 'EXECUTE')
union all
select 'admin_delete_expense', 'anon', has_function_privilege('anon', 'admin_delete_expense(uuid)', 'EXECUTE')
union all
select 'admin_delete_expense', 'authenticated', has_function_privilege('authenticated', 'admin_delete_expense(uuid)', 'EXECUTE');

-- ============================================================================
-- Not run yet. Next: apply this file with psql against $DATABASE_URL, then
-- run the verification queries above and report the actual output. Client
-- wiring (staff menu button, EOD rollup, admin delete UI, TX_LABELS/
-- ledgerEntryText support for 'expense'/'deleted_expense') is a separate,
-- later change - nothing in index.html calls any of these three functions
-- yet.
-- ============================================================================
