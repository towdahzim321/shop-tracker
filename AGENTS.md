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
- Production's `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA 
  public` grants `anon`/`authenticated` full privileges (`arwdDxtm` — 
  insert/select/update/delete/truncate/references/trigger/maintain) on 
  every relation `postgres` creates in `public` (confirmed live via 
  `pg_default_acl`, identical on production and staging). RLS still 
  gates a normal new table despite that grant — but a `postgres`-owned 
  VIEW over an RLS-enabled table bypasses that table's row-level 
  policies entirely (view-ownership exemption), so a newly created 
  view in `public` is fully anon-writable at the row level from the 
  moment it's created, unless explicitly revoked. `CREATE OR REPLACE 
  VIEW` on an existing view preserves its current grants and does not 
  re-trigger this; a fresh `CREATE VIEW` (including `DROP` + `CREATE`) 
  does. Any migration that creates a view in `public` must end with:
  ```sql
  begin;
  revoke all on <view> from public, anon, authenticated;
  grant select on <view> to anon, authenticated;  -- or narrower, per the view's intended readers
  commit;
  ```
  PG17 added `MAINTAIN` (the `m` in `arwdDxtm`) as a separately-grantable 
  privilege — use `revoke all`, not an enumerated list, or `MAINTAIN` 
  gets left behind. See `supabase-schema-security-4-staff-view-grant-
  hardening.sql` for a worked example (staff_public, phones_staff_view, 
  ledger_staff_view).

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
- On this Windows machine, `psql -f <path>` corrupts a function body that
  already contains literal `\r` bytes (see the CRLF note below) - it doubles
  each one into `\r\r\n`, evidently from Windows text-mode translation on the
  file read. Confirmed by capturing a function's `pg_get_functiondef()`
  output to a file and replaying it with `-f <path>` vs piping the same file
  through stdin (`cat file | psql -f -`): the stdin form reproduced the
  original byte-for-byte (confirmed with `cmp`), the filepath form did not.
  When byte-exact replay of captured DDL matters (e.g. restoring a function
  after a mutation test), pipe through stdin, don't pass a filepath to `-f`.
- Correction, found while applying `supabase-schema-security-5-staff-of-
  shop-search-path.sql`: stdin avoids the *doubling* bug above, but does
  NOT avoid `\r` appearing at all. `psql.exe` on this machine injects a
  single `\r` before every `\n` while reading stdin and storing a
  dollar-quoted body, even from a verified plain-`\n` source file - checked
  byte-for-byte that session: the source file was 0 CR / 115 LF, `cat`'s
  output captured right before the pipe was also 0 CR, but the live
  function body that resulted had CR count = LF count = CRLF-pair count,
  with zero doubled `\r\r`. So a plain-`\n` migration file is NOT "unaffected
  either way" as previously stated here - applying it by any method on this
  machine leaves it with `\r\n` line endings baked into the stored body.
  This is inert (Postgres's SQL/PL/pgSQL lexer treats `\r` as whitespace) -
  same conclusion as the CRLF note below - so it's not worth fighting. The
  check that actually matters when verifying a body wasn't corrupted is
  **zero occurrences of doubled `\r\r`**, not zero occurrences of `\r`
  (`grep`/`diff` are unreliable for this, per the CRLF note below - use
  `od -An -tx1 -v file | tr -d ' \n'` and count `0d0d` substrings; zero
  hits is clean, any hit is real doubling).

## Live testing: staging only, never production
- `DATABASE_URL` is production. `DATABASE_URL_STAGING` (also in `.env`) is a
  separate Supabase project holding a schema-only copy of production (no
  real staff, no real pin hashes, no real stock/ledger/daily_logs history)
  seeded only with the three real shop rows (harare/bulawayo1/bulawayo2,
  id+name+active+sort_order - not sensitive) and one fake staff member
  ("Staging Test Staff", shop harare, id df24e055-71c0-48ce-a104-
  be7e4f0808d8). Its PIN is `4291`, set during security-7's staff_sessions
  verification - noted here so a future session doesn't have to rediscover
  it (or reset it again, invalidating this note) just to call staff_login
  against staging.
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
- Known-benign byte-level difference (2026-08-27): staging's stored bodies
  for `staff_receive_stock`, `staff_open_day`, `staff_close_day`, and
  `staff_submit_eod` have `\r\n` line endings baked into every line, where
  production has plain `\n` - `pg_get_functiondef()` byte counts and `cmp`
  will show these four as differing even though the statements are
  word-for-word identical (confirmed with `od -c` at the divergence point:
  only the trailing `\r` differs). Root cause: `supabase-schema-part6e-
  remaining-idempotent.sql` (the file that created these four on staging)
  has CRLF line endings on disk, and applying it via `psql -f` on Windows
  preserved that literally inside the dollar-quoted function bodies;
  production was built through a path that normalized to LF. Inert -
  Postgres's SQL/PL/pgSQL lexer treats `\r` as whitespace - and left as-is
  deliberately: dropping and recreating four live functions to fix
  non-executing bytes is more risk than the condition itself. `diff` and
  `grep -c $'\r'` were both unreliable for detecting this in this
  environment (silently normalized/false-negatived); `od -c` is the tool
  that actually caught it.

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