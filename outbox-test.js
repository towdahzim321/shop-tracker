// Tests the outbox queue ENGINE in isolation - no UI, no action handlers,
// nothing wired to enqueueOutbox() yet (that's a later step). window.callRpc
// is monkey-patched to a controllable mock so these tests drive exact
// {ok, error, noReply} sequences rather than depending on real network
// conditions (those were already verified separately, against callRpc
// itself, in the detection-foundation work). Real Chromium timers are used
// for the FIFO test (fast enough not to matter); the stalled-threshold test
// uses Playwright's Clock API to fast-forward fake time instead of waiting
// 45 real minutes.
const { chromium } = require('playwright');
const path = require('path');
const FILE = 'file://' + path.resolve(__dirname, 'index.html');

let failures = 0;
const check = (n, c, x) => { if (c) console.log('  PASS  ' + n); else { failures++; console.log('  FAIL  ' + n + (x ? ' :: ' + x : '')); } };

// Boots the real index.html with real network blocked (so init()'s
// loadSettings/loadShopsAndModels fail fast and harmlessly, same as the
// app's own designed offline behaviour) and window.callRpc replaced with a
// controllable mock. Returns the page plus a handle to read/drive the mock.
async function newEngineOnlyPage(browser) {
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('  PAGEERROR:', e.message));
  await page.route('**/*supabase.co/**', route => route.abort('connectionrefused'));
  await page.goto(FILE);
  await page.waitForTimeout(500); // let init() finish its (blocked, harmless) boot

  await page.evaluate(() => {
    window.__mockCalls = [];
    window.__mockResults = []; // array of results to return, one per call, in order; last one repeats if exhausted
    window.__realCallRpc = window.callRpc;
    window.callRpc = function (name, params) {
      window.__mockCalls.push({ name, params: JSON.parse(JSON.stringify(params)) });
      const i = Math.min(window.__mockCalls.length - 1, window.__mockResults.length - 1);
      const res = window.__mockResults[i] || { ok: true, data: null, noReply: false };
      return Promise.resolve(res);
    };
  });

  return page;
}

async function setMockResults(page, results) {
  await page.evaluate((r) => { window.__mockResults = r; }, results);
}
async function getMockCalls(page) {
  return page.evaluate(() => window.__mockCalls);
}
async function waitUntil(page, fn, timeoutMs = 5000, intervalMs = 50) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await page.evaluate(fn)) return true;
    await page.waitForTimeout(intervalMs);
  }
  return false;
}

(async () => {
  const browser = await chromium.launch();

  // ===========================================================================
  console.log('\n== 1. Enqueue persists across a simulated reload ==');
  {
    const page = await newEngineOnlyPage(browser);
    await setMockResults(page, [{ ok: false, error: 'no reply', noReply: true }]);

    const entryId = await page.evaluate(() => enqueueOutbox({
      rpcName: 'staff_open_day',
      params: { p_shop_id: 'harare', p_staff_id: 's1', p_local_date: '2026-08-23', p_idempotency_key: 'key-open-1' },
      localDate: '2026-08-23',
      label: 'Open day (Harare CBD)'
    }));
    check('enqueueOutbox returns an id', typeof entryId === 'string' && entryId.length > 0, entryId);

    const rawBeforeReload = await page.evaluate(() => window.localStorage.getItem('twoutbox_v1'));
    const parsedBefore = JSON.parse(rawBeforeReload);
    check('localStorage has exactly one queued entry before reload', parsedBefore.queue.length === 1, rawBeforeReload);
    check('the stored entry keeps the exact idempotency key given, unchanged', parsedBefore.queue[0].params.p_idempotency_key === 'key-open-1', JSON.stringify(parsedBefore.queue[0].params));
    check('rpcName/localDate/label stored as given', parsedBefore.queue[0].rpcName === 'staff_open_day' && parsedBefore.queue[0].localDate === '2026-08-23' && parsedBefore.queue[0].label === 'Open day (Harare CBD)', JSON.stringify(parsedBefore.queue[0]));

    // Simulate the app being closed and reopened: a real reload, which runs
    // init() -> loadOutbox() again from scratch, from the SAME localStorage.
    await page.reload();
    await page.waitForTimeout(500);
    const afterReloadQueue = await page.evaluate(() => getOutboxQueue());
    check('entry is still in the in-memory queue after reload, re-hydrated from storage', afterReloadQueue.length === 1 && afterReloadQueue[0].id === entryId, JSON.stringify(afterReloadQueue));

    // The above only proves the DATA survived. It does not prove the retry
    // loop actually resumes firing on its own. A reload wipes the page's JS
    // state entirely, including the earlier window.callRpc monkeypatch - so
    // it has to be reapplied post-reload. init()'s own loadOutbox() +
    // scheduleNextOutboxAttempt() already ran (synchronously, before this
    // evaluate call) and armed a real setTimeout against the REAL callRpc,
    // but attemptSendHead() resolves `callRpc` by name at CALL time, not at
    // schedule time - so reapplying the mock now still intercepts it, as
    // long as it lands before the timer actually fires (well within its 5s
    // delay). No enqueueOutbox()/sendQueueNow() call happens here - if a
    // call reaches the mock, it can only be the resumed timer firing on its
    // own, unattended.
    await page.evaluate(() => {
      window.__mockCalls = [];
      window.__mockResults = [{ ok: false, error: 'still no reply', noReply: true }];
      window.callRpc = function (name, params) {
        window.__mockCalls.push({ name, params: JSON.parse(JSON.stringify(params)) });
        return Promise.resolve(window.__mockResults[0]);
      };
    });
    const resumedAutomatically = await waitUntil(page, () => window.__mockCalls.length >= 1, 8000, 100);
    check('the retry loop resumes firing attempts on its own after reload, no user action, per the backoff schedule', resumedAutomatically, 'mockCalls=' + JSON.stringify(await getMockCalls(page)));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 2. FIFO ordering with 2+ entries ==');
  {
    const page = await newEngineOnlyPage(browser);
    // Both succeed immediately (real reply, noReply:false) so the queue
    // drains one at a time without needing to wait out any backoff.
    await setMockResults(page, [{ ok: true, data: null, noReply: false }]);

    await page.evaluate(() => {
      enqueueOutbox({ rpcName: 'staff_sell_phone', params: { p_phone_id: 'pA', p_idempotency_key: 'key-A' }, localDate: '2026-08-23', label: 'Sale A' });
      enqueueOutbox({ rpcName: 'staff_return_phone', params: { p_phone_id: 'pB', p_idempotency_key: 'key-B' }, localDate: '2026-08-23', label: 'Sale B' });
    });
    check('both entries queued', (await page.evaluate(() => getOutboxQueue().length)) === 2);

    // Drive it explicitly via sendQueueNow() rather than waiting out real
    // backoff timers, for a fast, deterministic test.
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => window.__mockCalls.length >= 1);
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => window.__mockCalls.length >= 2);

    const calls = await getMockCalls(page);
    check('exactly 2 calls went out', calls.length === 2, JSON.stringify(calls.map(c => c.name)));
    check('entry A (queued first) was sent BEFORE entry B - strict FIFO', calls[0].params.p_idempotency_key === 'key-A' && calls[1].params.p_idempotency_key === 'key-B', JSON.stringify(calls.map(c => c.params.p_idempotency_key)));
    check('queue is empty after both succeed', (await page.evaluate(() => getOutboxQueue().length)) === 0);
    // Explicit, not just implied by the queue draining: ok:true must be a
    // plain removal, never routed to needs-attention (that's reserved for a
    // real reply that is an ERROR - see check 3 below).
    check('neither successful entry landed in needs-attention', (await page.evaluate(() => getOutboxNeedsAttention().length)) === 0, JSON.stringify(await page.evaluate(() => getOutboxNeedsAttention())));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 3. A real error response moves the entry to needs-attention, not a retry ==');
  {
    const page = await newEngineOnlyPage(browser);
    await setMockResults(page, [{ ok: false, error: 'This phone is no longer available for sale.', noReply: false }]);

    await page.evaluate(() => enqueueOutbox({
      rpcName: 'staff_sell_phone',
      params: { p_phone_id: 'pStale', p_idempotency_key: 'key-stale' },
      localDate: '2026-08-23',
      label: 'Sale - Galaxy A55 (Harare CBD)'
    }));
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => window.__mockCalls.length >= 1);
    await page.waitForTimeout(200); // let the state settle after the awaited call resolves

    const queue = await page.evaluate(() => getOutboxQueue());
    const needsAttention = await page.evaluate(() => getOutboxNeedsAttention());
    const calls = await getMockCalls(page);

    check('entry removed from the queue', queue.length === 0, JSON.stringify(queue));
    check('entry moved to needs-attention', needsAttention.length === 1, JSON.stringify(needsAttention));
    check('needs-attention entry keeps the label and the real error message', needsAttention[0] && needsAttention[0].label === 'Sale - Galaxy A55 (Harare CBD)' && needsAttention[0].error === 'This phone is no longer available for sale.', JSON.stringify(needsAttention[0]));
    check('only ONE call went out - a real reply is never retried', calls.length === 1, JSON.stringify(calls));

    // Prove it really isn't retried: force another manual send pass and
    // confirm no second call happens (nothing left in the queue to send).
    await page.evaluate(() => sendQueueNow());
    await page.waitForTimeout(300);
    const callsAfter = await getMockCalls(page);
    check('a further sendQueueNow() call does not re-attempt the resolved entry', callsAfter.length === 1, JSON.stringify(callsAfter));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 4. Stalled flag sets after the cumulative-attempt-time threshold (mocked clock, not real waiting) ==');
  {
    const page = await newEngineOnlyPage(browser);
    await page.clock.install({ time: new Date('2026-08-23T08:00:00Z') });
    await setMockResults(page, [{ ok: false, error: 'no reply', noReply: true }]); // perpetual silent failure

    await page.evaluate(() => enqueueOutbox({
      rpcName: 'staff_submit_eod',
      params: { p_shop_id: 'harare', p_idempotency_key: 'key-eod-stall' },
      localDate: '2026-08-23',
      label: 'EOD (Harare CBD)'
    }));

    const beforeFastForward = await page.evaluate(() => getOutboxQueue()[0]);
    check('entry starts not stalled', beforeFastForward.stalled === false, JSON.stringify(beforeFastForward));

    // Advance fake time well past the 45-minute threshold - runFor() (unlike
    // fastForward(), which only fires the single currently-due timer once)
    // processes the whole recursive chain: fires the 5s timer, awaits the
    // mocked callRpc, lets it reschedule the 15s timer, fires that too, and
    // so on through the steady 60s cadence - exactly what real time passing
    // would do, just without 50 real minutes of wall-clock waiting.
    await page.clock.runFor(50 * 60 * 1000); // 50 minutes of fake time

    const afterFastForward = await page.evaluate(() => getOutboxQueue()[0]);
    check('entry is stalled after >45 real minutes of attempt time', afterFastForward && afterFastForward.stalled === true, JSON.stringify(afterFastForward));
    check('stalled entry stays IN the queue, not removed', (await page.evaluate(() => getOutboxQueue().length)) === 1);
    check('attemptMs actually crossed the threshold', afterFastForward.attemptMs >= 45 * 60 * 1000, 'attemptMs=' + (afterFastForward && afterFastForward.attemptMs));

    const callsBeforeManual = (await getMockCalls(page)).length;
    check('several real attempts happened during the fast-forward (backoff was actually cycling)', callsBeforeManual >= 5, 'calls=' + callsBeforeManual);

    // Confirm it's still eligible for a manual trigger even though stalled.
    await page.evaluate(() => sendQueueNow());
    let callsAfterManual = callsBeforeManual;
    for (let i = 0; i < 50 && callsAfterManual <= callsBeforeManual; i++) {
      await page.waitForTimeout(50);
      callsAfterManual = (await getMockCalls(page)).length;
    }
    check('sendQueueNow() still attempts a stalled entry (manual trigger stays eligible)', callsAfterManual === callsBeforeManual + 1, `before=${callsBeforeManual} after=${callsAfterManual}`);

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 5. discardNeedsAttention() and retryNeedsAttentionEntry() ==');
  {
    const page = await newEngineOnlyPage(browser);

    // -- discard --
    await setMockResults(page, [{ ok: false, error: 'This phone is no longer available for sale.', noReply: false }]);
    await page.evaluate(() => enqueueOutbox({
      rpcName: 'staff_sell_phone', params: { p_phone_id: 'pDiscard', p_idempotency_key: 'key-discard' },
      localDate: '2026-08-23', label: 'Sale to discard'
    }));
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => window.__mockCalls.length >= 1);
    const naId = (await page.evaluate(() => getOutboxNeedsAttention()[0])).id;
    const discardResult = await page.evaluate((id) => discardNeedsAttention(id), naId);
    check('discardNeedsAttention() reports success', discardResult === true);
    check('entry is gone from needs-attention', (await page.evaluate(() => getOutboxNeedsAttention().length)) === 0);
    check('discarded entry did NOT reappear in the queue', (await page.evaluate(() => getOutboxQueue().length)) === 0);
    check('discarding a non-existent id reports false, not an error', (await page.evaluate((id) => discardNeedsAttention(id), 'no-such-id')) === false);

    // -- retry --
    await setMockResults(page, [{ ok: false, error: 'Today\'s business day is not open.', noReply: false }]);
    await page.evaluate(() => enqueueOutbox({
      rpcName: 'staff_receive_stock', params: { p_shop_id: 'harare', p_idempotency_key: 'key-retry-me' },
      localDate: '2026-08-23', label: 'Receive stock to retry'
    }));
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => window.__mockCalls.length >= 2); // 1 from discard test + 1 here
    const naEntry = await page.evaluate(() => getOutboxNeedsAttention()[0]);
    check('landed in needs-attention first, as expected', !!naEntry, JSON.stringify(naEntry));

    const retryResult = await page.evaluate((id) => retryNeedsAttentionEntry(id), naEntry.id);
    check('retryNeedsAttentionEntry() reports success', retryResult === true);
    check('removed from needs-attention', (await page.evaluate(() => getOutboxNeedsAttention().length)) === 0);
    const requeued = await page.evaluate(() => getOutboxQueue()[0]);
    check('re-enqueued at the back of the queue (queue was empty, so it is now the only/head entry)', requeued && requeued.id === naEntry.id, JSON.stringify(requeued));
    check('same params and idempotency key, unchanged', requeued && requeued.params.p_idempotency_key === 'key-retry-me' && requeued.rpcName === 'staff_receive_stock', JSON.stringify(requeued && requeued.params));
    check('retry state reset to fresh: attemptCount=0, attemptMs=0, stalled=false', requeued && requeued.attemptCount === 0 && requeued.attemptMs === 0 && requeued.stalled === false, JSON.stringify(requeued));

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 6. A stalled head blocks entries behind it - automatic AND manual - until it resolves ==');
  {
    const page = await newEngineOnlyPage(browser);
    await page.clock.install({ time: new Date('2026-08-23T08:00:00Z') });
    await setMockResults(page, [{ ok: false, error: 'no reply', noReply: true }]); // A fails forever, for now

    await page.evaluate(() => {
      enqueueOutbox({ rpcName: 'staff_open_day', params: { p_shop_id: 'harare', p_idempotency_key: 'key-A-openday' }, localDate: '2026-08-23', label: 'Open day (A)' });
      enqueueOutbox({ rpcName: 'staff_receive_stock', params: { p_shop_id: 'harare', p_idempotency_key: 'key-B-receive' }, localDate: '2026-08-23', label: 'Receive stock (B)' });
    });

    await page.clock.runFor(50 * 60 * 1000); // stall entry A, same technique as section 4
    const headAfterStall = await page.evaluate(() => getOutboxQueue()[0]);
    check('entry A is stalled', headAfterStall && headAfterStall.stalled === true, JSON.stringify(headAfterStall));
    check('entry B is still second in line, untouched', (await page.evaluate(() => getOutboxQueue()[1].params.p_idempotency_key)) === 'key-B-receive');

    const callsBeforeManual = (await getMockCalls(page)).length;
    check('B was never attempted automatically while A sat stalled at the head', (await getMockCalls(page)).every(c => c.params.p_idempotency_key === 'key-A-openday'), JSON.stringify(await getMockCalls(page)));

    // Manual trigger: per the design decision above, this must still only
    // touch the stalled HEAD (A), never skip ahead to B.
    await page.evaluate(() => sendQueueNow());
    let callsAfterManual = callsBeforeManual;
    for (let i = 0; i < 50 && callsAfterManual <= callsBeforeManual; i++) {
      await page.waitForTimeout(50);
      callsAfterManual = (await getMockCalls(page)).length;
    }
    const lastCall = (await getMockCalls(page)).slice(-1)[0];
    check('sendQueueNow() on a stalled head attempts A again, NOT B - no skip-ahead', lastCall.params.p_idempotency_key === 'key-A-openday', JSON.stringify(lastCall));
    check('B is still sitting in the queue, still untouched', (await page.evaluate(() => getOutboxQueue().length)) === 2 && (await page.evaluate(() => getOutboxQueue()[1].params.p_idempotency_key)) === 'key-B-receive');

    // Now let A finally resolve (a real reply, success) and confirm B
    // becomes reachable immediately afterward - the block was specifically
    // about ORDER, not a permanent lock.
    await setMockResults(page, [{ ok: true, data: null, noReply: false }]);
    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => getOutboxQueue().length === 1);
    const headNow = await page.evaluate(() => getOutboxQueue()[0]);
    check('A is gone, B is now the head', headNow && headNow.params.p_idempotency_key === 'key-B-receive', JSON.stringify(headNow));

    await page.evaluate(() => sendQueueNow());
    await waitUntil(page, () => getOutboxQueue().length === 0);
    const calls = await getMockCalls(page);
    check('B was finally attempted, in its turn, right after A resolved', calls.slice(-1)[0].params.p_idempotency_key === 'key-B-receive', JSON.stringify(calls.slice(-1)[0]));

    await page.close();
  }

  await browser.close();
  console.log('\n' + (failures === 0 ? 'ALL OUTBOX ENGINE CHECKS PASSED' : failures + ' FAILED'));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(1); });
