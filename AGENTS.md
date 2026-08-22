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

## Settled scope decisions (do not re-litigate)
- Do not auto-seed shop or reference rows — wait for explicit pasted 
  values before finalizing any row-level seed data.
- Staff device queries for daily logs are scoped to a 60-day window 
  (`staff_recent_daily_logs`). Older logs show as unsubmitted for 
  non-admin viewers — this is settled.