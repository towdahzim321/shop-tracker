-- ============================================================================
-- TOWDAH ELECTRONICS SHOP TRACKER — Schema Part 5: shops, models, IMEI rule
-- ============================================================================
-- Run this AFTER parts 1, 2, 3 and 4. Safe to re-run (idempotent): every
-- create uses "if not exists", every function uses "create or replace", and
-- the IMEI rule change checks the current state before it acts.
--
-- WHY THIS EXISTS
-- Two phones from different models can legitimately carry the same IMEI in
-- this trade. The current rule treats an IMEI as unique on its own, so the
-- second phone is refused and a real sale goes unrecorded. This part changes
-- the fingerprint of a phone from "IMEI" to "IMEI + model". It also stops the
-- shop list and the phone-model list from living in the app file, so the
-- owner can add a shop or a new model without anyone editing code.
--
-- SCOPE — READ THIS BEFORE RUNNING
-- Unlike part 4, this part is deliberately NOT scoped to one shop. It changes
-- table structure, which is shared by every shop by design. There is no
-- p_shop_id parameter and there should not be one.
-- The one thing to check by hand: this part DELETES NO ROWS. If any statement
-- below deletes or truncates business data, that is a bug — stop and fix it.
-- Data movement here is only ever: add a column, fill it in, add a table,
-- copy existing values into it.
--
-- WHAT THIS ADDS OR CHANGES
--   shops        — new table. Seeded with the three existing shops, keeping
--                  their exact current ids (harare, bulawayo1, bulawayo2) so
--                  every existing phone, ledger and day row still matches.
--   models       — new table. Seeded from the app's built-in model list PLUS
--                  every distinct model already sitting in phones, so nothing
--                  already in stock goes missing from the pick list.
--   phones       — gains a model_key column (the cleaned model name),
--                  backfilled from the model text already on each row.
--   phones index — the unique rule on imei alone is REMOVED and replaced by a
--                  unique rule on (imei, model_key).
--   functions    — admin_add_shop, admin_rename_shop, admin_close_shop,
--                  admin_rename_model, admin_set_model_brand,
--                  admin_hide_model. All guarded by require_admin(), the same
--                  guard every other admin_ function already uses.
--   staff_receive_stock — its duplicate check becomes (imei, model_key)
--                  instead of imei alone, and it auto-creates a model row when
--                  staff type a model that isn't on the list yet.
--
-- WHAT THIS LEAVES ALONE
--   Every existing phone, ledger, daily_log and business_day row — untouched,
--   values unchanged. Staff logins and PINs. Admin accounts. The low-stock
--   setting. The shop_resets history from part 4. All four existing tables
--   keep every row they have.
--
-- PRE-FLIGHT CHECK (must pass before the new index is created)
-- The new unique rule can only be created if no two existing phones already
-- share the same (imei, model_key). The SELECT below lists any such
-- collisions. If it returns rows, the index creation will fail loudly rather
-- than silently dropping data — that is intended. Fix the duplicates, then
-- re-run this file.
--
-- CLOSING, NOT DELETING
-- A shop is closed, never deleted. Its history stays readable forever; it
-- just stops appearing in the staff shop picker. Same for models: a model can
-- be hidden from the pick list, and hiding is refused outright if any phone
-- still references it.
--
-- AUDIT TRAIL
-- Adding, renaming or closing a shop, and renaming or hiding a model, each
-- write a ledger row naming the admin who did it and when — the same trail
-- every other admin action already leaves. A structural change should never
-- be untraceable after the fact.
--
-- TWO JUDGMENT CALLS MADE WRITING THIS FILE (neither was pinned down by the
-- brief, so read before running):
--
-- 1) "Write a ledger row" — admin_add_shop / admin_rename_shop /
--    admin_close_shop each act on ONE shop, so they write into that shop's
--    existing `ledger` table exactly as described, and will show up in the
--    app's own Transactions screen under "Corrections" once TX_LABELS knows
--    about the three new type strings (handled on the app side).
--    admin_rename_model / admin_set_model_brand / admin_hide_model are NOT
--    scoped to one shop — models are shared across all three shops - so
--    forcing them into one shop's ledger would misfile a global change under
--    an arbitrary shop. Those three write to a new `model_audit` table
--    instead (same idea as part 4's shop_resets). There is currently no
--    screen in the app that reads model_audit; it exists so the trail isn't
--    lost, not because the UI surfaces it yet.
--
-- 2) staff_receive_stock's CURRENT body is not visible from this repo (it was
--    defined in parts 1-3, which never got committed here). The version
--    below is rebuilt from the app's RPC call site and its test mock, not
--    copied from the live function. `create or replace function` only
--    replaces an existing function when the parameter types match EXACTLY —
--    if a type here is wrong, this creates a second, overloaded function
--    instead of replacing the real one, which Postgres/PostgREST will then
--    refuse to call at all ("function is not unique"). Before running this
--    file, it is worth running:
--      select pg_get_functiondef('staff_receive_stock'::regproc);
--    in the SQL editor and comparing its parameter list against the
--    definition below. If they differ, fix the signature here first.
-- ============================================================================


-- ---- Helper: the one place "cleaned model name" is defined -----------------
-- Trimmed, inner whitespace collapsed to a single space, lowercased. Used for
-- name_key on models, for phones.model_key, and inside staff_receive_stock.
create or replace function clean_model_key(p text)
returns text
language sql immutable as $$
  select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;


-- ---- shops -------------------------------------------------------------
-- CORRECTED: shops already exists in the live database - checked via
-- information_schema before writing this section, not assumed. It has
-- exactly two columns, both not null: id (text), name (text). No active, no
-- sort_order. The original version of this section used
-- "create table if not exists", which would have silently no-op'd against
-- the real table - every function below expecting shops.active or
-- shops.sort_order would then have failed at RUNTIME (first shop-close, or
-- first time the picker tried to sort) instead of failing loudly here,
-- where it's obvious and cheap to fix. So: ALTER, not CREATE.
alter table shops add column if not exists active boolean not null default true;
alter table shops add column if not exists sort_order int not null default 0;

-- Confirm id is the primary key; add it if for some reason it isn't. Checked
-- at runtime rather than assumed, same reasoning as above.
do $$
begin
  if not exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public' and table_name = 'shops' and constraint_type = 'PRIMARY KEY'
  ) then
    alter table shops add primary key (id);
  end if;
end $$;

-- RLS on shops was already in place before this file (shops_read_all,
-- {public}/SELECT/true, confirmed via pg_policies) - these statements are
-- idempotent re-declarations of that same shape, plus the admin-only
-- insert/update policies that did NOT already exist. All safe to re-run.
alter table shops enable row level security;
drop policy if exists shops_select_all on shops;
create policy shops_select_all on shops for select using (true);
drop policy if exists shops_admin_insert on shops;
create policy shops_admin_insert on shops for insert with check (is_admin());
drop policy if exists shops_admin_update on shops;
create policy shops_admin_update on shops for update using (is_admin()) with check (is_admin());

-- ---- SEEDING: NOT YET WRITTEN -----------------------------------------
-- Waiting on the owner to paste the actual `select * from shops` rows
-- before this is finalised - one message contained both "here are the
-- rows, they match" AND "don't finalise until I paste them," and the
-- second is the one being treated as binding here. Once confirmed, this
-- becomes an update-if-exists / insert-if-not per shop (reconcile, never a
-- blind INSERT, and never a second row for an id that's already present):
--
--   insert into shops (id, name, active, sort_order) values ('harare', 'Harare CBD', true, 1)
--     on conflict (id) do update set name = excluded.name;
--   -- ... same shape for bulawayo1 (sort_order 2) and bulawayo2 (sort_order 3)
--
-- sort_order is set explicitly per shop (1/2/3), not left at the column
-- default of 0 for all three - leaving them all at 0 would make the picker
-- order arbitrary, which staff would notice. If the real ids turn out to
-- differ from harare/bulawayo1/bulawayo2, this whole block - and the
-- assumption that existing phones/ledger/business_day rows already point
-- at those exact ids - needs rethinking before it's written, not after.


-- ---- models --------------------------------------------------------------
create table if not exists models (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_key text not null unique,
  brand text,
  active boolean not null default true,
  created_by uuid references staff(id),
  created_at timestamptz not null default now()
);
alter table models enable row level security;
drop policy if exists models_select_all on models;
create policy models_select_all on models for select using (true);
drop policy if exists models_admin_insert on models;
create policy models_admin_insert on models for insert with check (is_admin());
drop policy if exists models_admin_update on models;
create policy models_admin_update on models for update using (is_admin()) with check (is_admin());

-- Seed from the app's built-in pick list (MODEL_CATALOG). This only ever
-- needs to run once - the pick list itself now lives in this table, not in
-- the app file.
insert into models (name, name_key, brand, active) values
  ('Galaxy A04', clean_model_key('Galaxy A04'), 'Samsung', true),
  ('Galaxy A05', clean_model_key('Galaxy A05'), 'Samsung', true),
  ('Galaxy A05s', clean_model_key('Galaxy A05s'), 'Samsung', true),
  ('Galaxy A06', clean_model_key('Galaxy A06'), 'Samsung', true),
  ('Galaxy A14', clean_model_key('Galaxy A14'), 'Samsung', true),
  ('Galaxy A15', clean_model_key('Galaxy A15'), 'Samsung', true),
  ('Galaxy A16', clean_model_key('Galaxy A16'), 'Samsung', true),
  ('Galaxy A24', clean_model_key('Galaxy A24'), 'Samsung', true),
  ('Galaxy A25', clean_model_key('Galaxy A25'), 'Samsung', true),
  ('Galaxy A26', clean_model_key('Galaxy A26'), 'Samsung', true),
  ('Galaxy A34', clean_model_key('Galaxy A34'), 'Samsung', true),
  ('Galaxy A35', clean_model_key('Galaxy A35'), 'Samsung', true),
  ('Galaxy A36', clean_model_key('Galaxy A36'), 'Samsung', true),
  ('Galaxy A54', clean_model_key('Galaxy A54'), 'Samsung', true),
  ('Galaxy A55', clean_model_key('Galaxy A55'), 'Samsung', true),
  ('Galaxy A56', clean_model_key('Galaxy A56'), 'Samsung', true),
  ('Galaxy S20', clean_model_key('Galaxy S20'), 'Samsung', true),
  ('Galaxy S20 Ultra', clean_model_key('Galaxy S20 Ultra'), 'Samsung', true),
  ('Galaxy S21', clean_model_key('Galaxy S21'), 'Samsung', true),
  ('Galaxy S21 Ultra', clean_model_key('Galaxy S21 Ultra'), 'Samsung', true),
  ('Galaxy S22', clean_model_key('Galaxy S22'), 'Samsung', true),
  ('Galaxy S22 Ultra', clean_model_key('Galaxy S22 Ultra'), 'Samsung', true),
  ('Galaxy S23', clean_model_key('Galaxy S23'), 'Samsung', true),
  ('Galaxy S23 Ultra', clean_model_key('Galaxy S23 Ultra'), 'Samsung', true),
  ('Galaxy S24', clean_model_key('Galaxy S24'), 'Samsung', true),
  ('Galaxy S24 Ultra', clean_model_key('Galaxy S24 Ultra'), 'Samsung', true),
  ('Galaxy S25', clean_model_key('Galaxy S25'), 'Samsung', true),
  ('Galaxy S25 Ultra', clean_model_key('Galaxy S25 Ultra'), 'Samsung', true),
  ('Galaxy Note 10', clean_model_key('Galaxy Note 10'), 'Samsung', true),
  ('Galaxy Note 20', clean_model_key('Galaxy Note 20'), 'Samsung', true),
  ('Galaxy Note 20 Ultra', clean_model_key('Galaxy Note 20 Ultra'), 'Samsung', true),
  ('Galaxy Z Flip 4', clean_model_key('Galaxy Z Flip 4'), 'Samsung', true),
  ('Galaxy Z Flip 5', clean_model_key('Galaxy Z Flip 5'), 'Samsung', true),
  ('Galaxy Z Flip 6', clean_model_key('Galaxy Z Flip 6'), 'Samsung', true),
  ('Galaxy Z Fold 4', clean_model_key('Galaxy Z Fold 4'), 'Samsung', true),
  ('Galaxy Z Fold 5', clean_model_key('Galaxy Z Fold 5'), 'Samsung', true),
  ('Galaxy Z Fold 6', clean_model_key('Galaxy Z Fold 6'), 'Samsung', true),
  ('iPhone 7', clean_model_key('iPhone 7'), 'iPhone', true),
  ('iPhone 8', clean_model_key('iPhone 8'), 'iPhone', true),
  ('iPhone X', clean_model_key('iPhone X'), 'iPhone', true),
  ('iPhone XR', clean_model_key('iPhone XR'), 'iPhone', true),
  ('iPhone XS', clean_model_key('iPhone XS'), 'iPhone', true),
  ('iPhone XS Max', clean_model_key('iPhone XS Max'), 'iPhone', true),
  ('iPhone 11', clean_model_key('iPhone 11'), 'iPhone', true),
  ('iPhone 11 Pro', clean_model_key('iPhone 11 Pro'), 'iPhone', true),
  ('iPhone 11 Pro Max', clean_model_key('iPhone 11 Pro Max'), 'iPhone', true),
  ('iPhone 12', clean_model_key('iPhone 12'), 'iPhone', true),
  ('iPhone 12 Mini', clean_model_key('iPhone 12 Mini'), 'iPhone', true),
  ('iPhone 12 Pro', clean_model_key('iPhone 12 Pro'), 'iPhone', true),
  ('iPhone 12 Pro Max', clean_model_key('iPhone 12 Pro Max'), 'iPhone', true),
  ('iPhone 13', clean_model_key('iPhone 13'), 'iPhone', true),
  ('iPhone 13 Mini', clean_model_key('iPhone 13 Mini'), 'iPhone', true),
  ('iPhone 13 Pro', clean_model_key('iPhone 13 Pro'), 'iPhone', true),
  ('iPhone 13 Pro Max', clean_model_key('iPhone 13 Pro Max'), 'iPhone', true),
  ('iPhone 14', clean_model_key('iPhone 14'), 'iPhone', true),
  ('iPhone 14 Plus', clean_model_key('iPhone 14 Plus'), 'iPhone', true),
  ('iPhone 14 Pro', clean_model_key('iPhone 14 Pro'), 'iPhone', true),
  ('iPhone 14 Pro Max', clean_model_key('iPhone 14 Pro Max'), 'iPhone', true),
  ('iPhone 15', clean_model_key('iPhone 15'), 'iPhone', true),
  ('iPhone 15 Plus', clean_model_key('iPhone 15 Plus'), 'iPhone', true),
  ('iPhone 15 Pro', clean_model_key('iPhone 15 Pro'), 'iPhone', true),
  ('iPhone 15 Pro Max', clean_model_key('iPhone 15 Pro Max'), 'iPhone', true),
  ('iPhone 16', clean_model_key('iPhone 16'), 'iPhone', true),
  ('iPhone 16 Plus', clean_model_key('iPhone 16 Plus'), 'iPhone', true),
  ('iPhone 16 Pro', clean_model_key('iPhone 16 Pro'), 'iPhone', true),
  ('iPhone 16 Pro Max', clean_model_key('iPhone 16 Pro Max'), 'iPhone', true),
  ('iPhone SE', clean_model_key('iPhone SE'), 'iPhone', true)
on conflict (name_key) do nothing;

-- Seed from whatever models are already sitting in phones (covers anything
-- typed in via "Not listed" before this migration ran). Brand is left null -
-- the admin can set it later via admin_set_model_brand. For each distinct
-- name_key, the earliest-received row's exact text/casing is kept as the
-- canonical display name.
insert into models (name, name_key, brand, active, created_at)
  select distinct on (clean_model_key(model))
    model, clean_model_key(model), null, true, now()
  from phones
  where model is not null and trim(model) <> ''
  order by clean_model_key(model), received_ts asc nulls last
on conflict (name_key) do nothing;


-- ---- phones.model_key ------------------------------------------------------
-- A generated column rather than a plain backfilled one: it can never drift
-- out of sync with `model` (Postgres recomputes it for every existing row
-- the moment this statement runs, which IS the backfill - no separate UPDATE
-- needed), and every future insert gets it for free.
alter table phones add column if not exists model_key text
  generated always as (clean_model_key(model)) stored;


-- ---- PRE-FLIGHT CHECK: run and read this before trusting the index below --
-- If this returns any rows, two existing phones already collide on
-- (imei, model_key) and the unique index further down WILL fail to create.
-- Fix those rows first (they are almost certainly a genuine duplicate entry
-- that predates this migration), then re-run this file.
select imei, model_key, count(*) as how_many, array_agg(id) as phone_ids
from phones
group by imei, model_key
having count(*) > 1;

do $$
declare v_collisions int;
begin
  select count(*) into v_collisions
  from (select 1 from phones group by imei, model_key having count(*) > 1) x;
  if v_collisions > 0 then
    raise exception 'Cannot proceed: % existing phone(s) collide on (imei, model_key). See the pre-flight SELECT above, fix the duplicates, then re-run this file.', v_collisions;
  end if;
end $$;

-- The old rule (unique on imei alone) is a CONSTRAINT, which owns a matching
-- index of the same name - dropping the constraint drops both in one step.
alter table phones drop constraint if exists phones_imei_key;
create unique index if not exists phones_imei_model_key_idx on phones using btree (imei, model_key);


-- ---- admin_add_shop / admin_rename_shop / admin_close_shop -----------------
-- The id is derived from the name (letters/digits only, lowercased), the
-- same shape as the existing "bulawayo1"/"bulawayo2" ids, with a numeric
-- suffix appended only if that slug is already taken.
create or replace function admin_add_shop(p_name text)
returns text
language plpgsql security definer as $$
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
  -- The while-loop above already guarantees v_id is free at the moment it
  -- was checked, but two admins adding a shop with the same name at the
  -- same instant could both pass that check before either inserts. Catch
  -- that race explicitly so it surfaces as the same readable message as
  -- every other refusal here, not a raw unique-constraint error.
  begin
    insert into shops (id, name, active, sort_order) values (v_id, trim(p_name), true, v_next_order);
  exception when unique_violation then
    raise exception 'A shop with this id already exists.';
  end;

  insert into ledger (id, shop_id, ts, type, by_admin, note)
  values (gen_random_uuid(), v_id, now(), 'shop_added', v_who, 'Added shop "'||trim(p_name)||'" ('||v_id||')');

  return v_id;
end; $$;

create or replace function admin_rename_shop(p_shop_id text, p_new_name text)
returns void
language plpgsql security definer as $$
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
end; $$;

create or replace function admin_close_shop(p_shop_id text)
returns void
language plpgsql security definer as $$
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
end; $$;


-- ---- admin_rename_model / admin_set_model_brand / admin_hide_model --------
-- Not shop-scoped (models are shared across every shop) - logged to
-- model_audit rather than any one shop's ledger. See the note near the top
-- of this file for why.
create table if not exists model_audit (
  id uuid primary key default gen_random_uuid(),
  ts timestamptz not null default now(),
  action text not null,
  model_id uuid not null,
  by_admin text not null,
  note text
);
alter table model_audit enable row level security;
drop policy if exists model_audit_admin_all on model_audit;
create policy model_audit_admin_all on model_audit for all using (is_admin()) with check (is_admin());

create or replace function admin_rename_model(p_model_id uuid, p_new_name text)
returns void
language plpgsql security definer as $$
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
end; $$;

create or replace function admin_set_model_brand(p_model_id uuid, p_brand text)
returns void
language plpgsql security definer as $$
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
end; $$;

create or replace function admin_hide_model(p_model_id uuid)
returns void
language plpgsql security definer as $$
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
end; $$;


-- ---- staff_receive_stock: duplicate check becomes (imei, model_key) -------
-- See the note near the top of this file: this body is reconstructed from
-- the app's call site and its test mock, not copied from the live function.
-- Verify the parameter signature against the real function before running.
--
-- The whole document is refused as one unit (nothing partially saved) if any
-- (imei, model) pair is already on record OR repeated within this same
-- document - relying on the real unique index below as the source of truth,
-- the same way the pre-flight check above relies on it rather than trusting
-- a hand-written duplicate scan. Unknown models are inserted into `models`
-- as part of this same transaction, so a typo'd-but-real model never blocks
-- a sale.
create or replace function staff_receive_stock(
  p_shop_id text, p_staff_id uuid, p_local_date date, p_items jsonb
)
returns int
language plpgsql security definer as $$
declare
  v_day_status text;
  v_item jsonb;
  v_imei text;
  v_model text;
  v_description text;
  v_model_key text;
  v_batch_id uuid;
  v_phone_id uuid;
  v_count int := 0;
begin
  if not exists (select 1 from staff where id = p_staff_id and shop_id = p_shop_id and active) then
    raise exception 'Staff member not recognised for this shop.';
  end if;

  select status into v_day_status from business_days where shop_id = p_shop_id and date = p_local_date;
  if v_day_status is distinct from 'open' then
    raise exception 'Today''s business day is not open. Open it before adding entries.';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_model := v_item->>'model';
    v_description := nullif(v_item->>'description', '');
    v_model_key := clean_model_key(v_model);
    v_batch_id := gen_random_uuid();

    insert into models (name, name_key, active, created_by)
      values (trim(v_model), v_model_key, true, p_staff_id)
      on conflict (name_key) do nothing;

    for v_imei in select * from jsonb_array_elements_text(coalesce(v_item->'imeis', '[]'::jsonb))
    loop
      begin
        insert into phones (id, shop_id, imei, model, description, batch_id, status, date_received, received_ts, received_by)
        values (gen_random_uuid(), p_shop_id, v_imei, v_model, v_description, v_batch_id, 'in_stock', p_local_date, now(), p_staff_id)
        returning id into v_phone_id;
      exception when unique_violation then
        raise exception 'Already recorded: % (%)', v_imei, v_model;
      end;

      insert into ledger (id, shop_id, ts, type, phone_id, model, description, imei, by_staff, extra)
      values (gen_random_uuid(), p_shop_id, now(), 'received', v_phone_id, v_model, v_description, v_imei, p_staff_id, jsonb_build_object('batchId', v_batch_id));

      v_count := v_count + 1;
    end loop;
  end loop;

  return v_count;
end; $$;

-- ============================================================================
-- Done. Next: open the app, go to Settings - the "Shops" and "Models"
-- sections only work once index.html is updated to match (separate change).
-- ============================================================================
