## Schema migrations — deployment safety
- Never bundle a new function/view/RPC with removal of the old policy or 
  column it replaces in the same file. Split any breaking or policy-
  affecting rollout into three files:
  1. Additive only (new views, new RPCs, new helpers) — safe to deploy alone
  2. Client rollout — deploy and verify client changes against the new layer
  3. Removals only (drop legacy policies/overloads) — only after step 2 
     is confirmed working
- This 3-step split applies to POLICY and COLUMN removals only, where the 
  old and new can safely coexist for a while — a dropped policy or column 
  doesn't break anything until it's actually removed. Function SIGNATURE 
  changes are the opposite: two overloads of the same function cannot 
  coexist even briefly (PostgREST can't disambiguate between them, and 
  every call to that function fails immediately, not just new ones). So 
  signature changes are single-file, not split: create the new signature, 
  drop the exact old one, NOTIFY pgrst — all together — with the client 
  cutover to actually using the new parameter held back as its own separate 
  last step, since a default-valued new parameter keeps the unchanged 
  client working against the new signature in the meantime. See "Function 
  signature changes" below.
- Before drafting any DDL, check the live schema (information_schema or 
  schema.dump.sql) — never assume a column, table, or auth mechanism 
  exists based on a prior plan. Confirm against the real database first.
- Staff authenticate via `pin_hash` (bcrypt, NOT NULL). There is no 
  plaintext `pin` column and never was — do not propose dual-mode login 
  or backfill scripts for this.

## Function signature changes
- Never use CREATE OR REPLACE FUNCTION when the parameter list changes — 
  Postgres treats it as a new overload, not a replacement, and PostgREST 
  can't disambiguate. Any signature change must explicitly DROP FUNCTION 
  on the old signature and issue NOTIFY pgrst, 'reload schema'.

## Grants
- REVOKE ... FROM PUBLIC does not block Supabase's default access — 
  Supabase grants EXECUTE directly to anon and authenticated. Every 
  revoke must explicitly list `public, anon, authenticated`, followed 
  by a verification query.

## Client/server parity
- Any server-side business rule change (uniqueness constraints, required 
  fields, etc.) must be checked against every client-facing view that 
  mirrors that data, and updated in the same change.
- Staff-facing views must stay additive and must never expose 
  `cost_price`, `pin_hash`, or other admin-only columns.

## Applying migrations
- Migrations are applied with psql using $DATABASE_URL from .env, never 
  through the Supabase dashboard.
- Always run the file's verification query afterwards and report the 
  actual output, not a summary.

## Live testing: staging only, never production
- `DATABASE_URL` is production. `DATABASE_URL_STAGING` (also in `.env`) is a
  separate Supabase project holding a schema-only copy of production (no
  real staff, no real pin hashes, no real stock/ledger/daily_logs history)
  seeded only with the three real shop rows (harare/bulawayo1/bulawayo2,
  id+name+active+sort_order - not sensitive) and one fake staff member.
- Any test that drives the actual app against a real Supabase backend -
  button-lock behavior, network-throttling/rapid-tap tests, "does this
  actually land one row not five," multi-step same-visit flows, anything
  beyond the in-memory mock in supabase-test.js - runs against
  DATABASE_URL_STAGING and a build of index.html pointed at the staging
  project's URL/anon key, never against production.
- When staging's schema drifts from production (a new migration applied to
  one but not the other), re-sync it with a fresh `pg_dump --schema-only`
  from production before trusting staging test results again - don't test
  against a staging schema you haven't confirmed matches.

## Settled scope decisions (do not re-litigate)
- Do not auto-seed shop or reference rows — wait for explicit pasted 
  values before finalizing any row-level seed data.
- Staff device queries for daily logs are scoped to a 60-day window 
  (`staff_recent_daily_logs`). Older logs show as unsubmitted for 
  non-admin viewers — this is settled.

## Known accepted trade-offs
- `RENDER_PENDING` (client, index.html): records that a background render 
  (outbox bar, realtime `bump()`, `pollTick()`) was suppressed while 
  `CRITICAL_FLOW_IN_PROGRESS` was true, so the owning handler's `finally` 
  can render once to catch up. On a graceful RPC failure, five screens - 
  sell phone, client return, submit EOD, staff PIN entry, admin login - 
  clear the flag without rendering instead: they patch only their own 
  error element (`priceErr`/`returnErr`/`eodErr`/`pinErr`/`adminErr`), and 
  a real render() right after would blank out that just-shown error under 
  a flaky connection - worse than the render staying owed. This is safe 
  only because none of those five screens display anything backed by live 
  `SHOP_CACHE` data - if any of them starts showing SHOP_CACHE-derived 
  content, this trade-off needs revisiting (either render there too, or 
  patch in the fresher data alongside the error). Each call site carries a 
  one-line comment noting this.

## Vendored dependencies (client)
- `supabase-js.2.112.4.js` (repo root) is `@supabase/supabase-js@2.112.4`'s 
  published UMD browser bundle (the same file its own `package.json` 
  `jsdelivr`/`unpkg` fields point at: `dist/umd/supabase.js`), vendored 
  in-repo instead of loaded from `cdn.jsdelivr.net` at page load.
  - Why: the CDN was a single third-party point of failure at load time - a 
    blocked/failed fetch (content blocker, restrictive network) left 
    `window.supabase` undefined with no retry, which `index.html`'s `init()` 
    silently turned into the same "not connected to database" banner used 
    for a real outage, on one browser but not another on the same device.
  - SHA256 of the vendored file: 
    `f8ce7fab799af1916019cbd0b485b39bb80dbdbc6dc062909a751c9e5198e04c`
  - To update the version: pull the new version's tarball from the npm 
    registry (`npm pack @supabase/supabase-js@<version>`, not jsdelivr - use 
    the canonical published artifact), confirm its `package.json` 
    `jsdelivr`/`unpkg` field still points at `dist/umd/supabase.js`, copy 
    that file in as `supabase-js.<version>.js`, update the `<script>` tag's 
    `src` in `index.html`, record the new hash here, and remove the old 
    version's file. Deliberately a manual, visible step - never re-point 
    the existing filename at different content.