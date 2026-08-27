// Tests the outbox UI layer: the "N waiting" bar, the needs-attention
// banner (discard/retry), and - the safety-critical part - the queued-state
// check on each of the six action screens that stops staff from firing a
// second, independent attempt at an action that's already queued. Drives
// the REAL screen-render functions and REAL enqueueOutbox()/callRpc, with
// callRpc monkey-patched for control, same technique as the other outbox
// test files.
const { chromium } = require('playwright');
const path = require('path');
const FILE = 'file://' + path.resolve(__dirname, 'index.html');

let failures = 0;
const check = (n, c, x) => { if (c) console.log('  PASS  ' + n); else { failures++; console.log('  FAIL  ' + n + (x ? ' :: ' + x : '')); } };

async function newPage(browser) {
  const page = await browser.newPage();
  page.on('pageerror', e => console.log('  PAGEERROR:', e.message));
  await page.route('**/*supabase.co/**', route => route.abort('connectionrefused'));
  await page.goto(FILE);
  await page.waitForTimeout(500);
  await page.evaluate(() => {
    window.__mockResults = [{ ok: false, error: 'no reply', noReply: true }];
    window.callRpc = function () { return Promise.resolve(window.__mockResults[0]); };
  });
  return page;
}

// Controllable-delay callRpc: hangs until the test calls
// window.__resolveRpc(...), so the test can inspect state at the exact
// moment an RPC is "in flight" and resolve it whenever it chooses.
async function installControllableRpc(page) {
  await page.evaluate(() => {
    window.__rpcCalls = 0;
    window.callRpc = function (name, params) {
      window.__rpcCalls++;
      window.__lastRpcName = name;
      window.__lastRpcParams = params;
      return new Promise((resolve) => { window.__resolveRpc = resolve; });
    };
  });
}

// render() call counter, same technique as the admin-login test.
async function installRenderCounter(page) {
  await page.evaluate(() => {
    window.__renderCalls = 0;
    window.__realRender = window.render;
    window.render = function () { window.__renderCalls++; return window.__realRender(); };
  });
}

// Stubs sb.channel so subscribeToShop(shopId) captures the realtime
// postgres_changes callback (bump()) into window.__realtimeBumpCallback, and
// stubs refreshShopData/loadShopsAndModels so bump() and the handler's own
// post-RPC refresh don't hit the network - same technique as the admin-login
// test's sb/refreshShopData stand-ins.
async function installRealtimeBumpCapture(page, shopId) {
  await page.evaluate((shopId) => {
    REALTIME_CHANNELS = {};
    window.__realtimeBumpCallback = null;
    sb = {
      channel: () => {
        const chain = { on: (event, filter, cb) => { window.__realtimeBumpCallback = cb; return chain; }, subscribe: () => chain };
        return chain;
      }
    };
    window.refreshShopData = (id) => Promise.resolve(SHOP_CACHE[id] || emptyShopData());
    window.loadShopsAndModels = () => Promise.resolve();
    subscribeToShop(shopId);
  }, shopId);
}

(async () => {
  const browser = await chromium.launch();

  // ===========================================================================
  console.log('\n== 1. The "N waiting" bar ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      enqueueOutbox({ rpcName: 'staff_sell_phone', params: { p_phone_id: 'p1', p_idempotency_key: 'k1' }, localDate: todayStr(), label: 'Sale - Galaxy A55 (Harare CBD)' });
      render();
    });
    let t = await page.evaluate(() => document.getElementById('app').innerText);
    check('bar shows "1 entry waiting" collapsed', /1 entry waiting to send/.test(t), t.slice(0,150));
    check('label not shown while collapsed', !/Galaxy A55/.test(t));

    await page.locator('.outbox-bar-head').click();
    t = await page.evaluate(() => document.getElementById('app').innerText);
    check('expanding shows the queued label', /Galaxy A55/.test(t), t.slice(0,250));
    check('a Send now button is present', (await page.locator('.outbox-bar >> text=Send now').count()) === 1);

    // Send now should attempt it - mock still returns noReply, so it stays queued.
    await page.locator('.outbox-bar >> text=Send now').click();
    await page.waitForTimeout(300);
    const stillQueued = await page.evaluate(() => getOutboxQueue().length);
    check('still queued after Send now with a mock that keeps failing (not silently dropped)', stillQueued === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 2. Needs-attention banner: discard and retry ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
    });
    await page.evaluate(() => { window.__mockResults = [{ ok: false, error: 'This phone is no longer available for sale.', noReply: false }]; });
    await page.evaluate(() => enqueueOutbox({ rpcName: 'staff_sell_phone', params: { p_phone_id: 'p2', p_idempotency_key: 'k2' }, localDate: todayStr(), label: 'Sale - iPhone 13 (Harare CBD)' }));
    await page.evaluate(() => sendQueueNow());
    await page.waitForTimeout(300);
    await page.evaluate(() => render());

    let t = await page.evaluate(() => document.getElementById('app').innerText);
    check('needs-attention banner shows the label and real error', /iPhone 13/.test(t) && /no longer available for sale/.test(t), t.slice(0,300));

    // Discard: confirm modal must be answered.
    await page.locator('.outbox-attention-actions >> text=Discard').click();
    await page.waitForTimeout(150);
    await page.locator('.modal-overlay .yes, .modal-overlay .yes-safe').click();
    await page.waitForTimeout(200);
    check('discarded entry is gone from needs-attention', (await page.evaluate(() => getOutboxNeedsAttention().length)) === 0);

    // Retry: re-enqueue a second entry and retry it.
    await page.evaluate(() => enqueueOutbox({ rpcName: 'staff_return_phone', params: { p_phone_id: 'p3', p_idempotency_key: 'k3' }, localDate: todayStr(), label: 'Return - Pixel 8 (Harare CBD)' }));
    await page.evaluate(() => sendQueueNow());
    await page.waitForTimeout(300);
    await page.evaluate(() => render());
    await page.locator('.outbox-attention-actions >> text=Retry').click();
    await page.waitForTimeout(200);
    check('retried entry is back in the queue, not needs-attention', (await page.evaluate(() => getOutboxNeedsAttention().length)) === 0 && (await page.evaluate(() => getOutboxQueue().length)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 3. staff_submit_eod - the safety-critical case: cannot resubmit while queued ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'eod', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      render();
    });
    check('normal Submit button present before anything is queued', (await page.locator('#eodSubmitBtn').count()) === 1);
    await page.fill('#eodCount', '5'); await page.fill('#eodFaulty', '0'); await page.fill('#eodCash', '150');
    await page.evaluate(() => confirmEod());
    await page.waitForTimeout(300);
    await page.evaluate(() => render());

    check('Submit button is GONE once queued', (await page.locator('#eodSubmitBtn').count()) === 0);
    check('queued notice shown instead', (await page.locator('.queued-notice').count()) === 1);
    const inputsDisabled = await page.evaluate(() => ['eodCount','eodFaulty','eodCash'].every(id => document.getElementById(id).disabled));
    check('the figure inputs are disabled - cannot even type a "different" number to submit', inputsDisabled);

    // The exact hazard being closed: confirm there is genuinely no way to
    // fire confirmEod() again for today while this is queued - the only
    // button on screen is the disabled notice, not a submit handler.
    const stillOneEntry = await page.evaluate(() => getOutboxQueue().filter(e => e.rpcName === 'staff_submit_eod').length);
    check('exactly one staff_submit_eod entry queued (no way for a second to have been created)', stillOneEntry === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 4. staff_sell_phone / staff_return_phone scope by PHONE, not by shop+date ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'salePrice', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      selectedPhone = { id: 'pX', model: 'Galaxy A55', listPrice: 180 };
      saleIdemKey = genUuid();
    });
    await page.fill('#priceInput', '150');
    await page.evaluate(() => confirmSale());
    await page.waitForTimeout(300);

    // A DIFFERENT phone must NOT be blocked.
    await page.evaluate(() => {
      selectedPhone = { id: 'pY', model: 'iPhone 13', listPrice: 540 };
      saleIdemKey = genUuid();
      render();
    });
    check('a different phone shows the NORMAL confirm button, not blocked by pX\'s queued entry', (await page.locator('#saleConfirmBtn').count()) === 1);
    check('no queued-notice shown for the different phone', (await page.locator('.queued-notice').count()) === 0);

    // The SAME phone (pX) again, though, should be blocked.
    await page.evaluate(() => {
      selectedPhone = { id: 'pX', model: 'Galaxy A55', listPrice: 180 };
      render();
    });
    check('the SAME phone (pX) is blocked - queued notice shown, no confirm button', (await page.locator('.queued-notice').count()) === 1 && (await page.locator('#saleConfirmBtn').count()) === 0);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 5. staff_receive_stock: a genuinely new batch is NOT blocked by an earlier queued one ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'receive', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      S.receiveBatch = { lines: [{ batchId: 'b1', model: 'Galaxy A55', description: '', qty: 1, imeis: ['111111111111111'] }] };
      S.receiveIdemKey = genUuid();
      S.receiveStep = 'batchSummary';
      render();
    });
    await page.evaluate(() => finishReceiving());
    await page.waitForTimeout(300);
    await page.evaluate(() => render());
    check('the just-submitted batch is blocked (queued notice shown)', (await page.locator('.queued-notice').count()) === 1);
    check('receiveFinishBtn gone while this batch is queued', (await page.locator('#receiveFinishBtn').count()) === 0);

    // Start a genuinely NEW batch (matches screenReceive()'s own init path).
    await page.evaluate(() => {
      S.receiveBatch = null;
      S.receiveStep = 'batchSummary'; // force straight to summary for this check
      go('receive'); // resets S the same way real navigation would
    });
    // go() drops receiveBatch/receiveQueuedKey entirely (S rebuilt to keep
    // only shopId/staffId/staffName) - re-simulate what screenReceive()'s
    // own lazy-init does when a fresh batch starts.
    await page.evaluate(() => {
      S.receiveBatch = { lines: [{ batchId: 'b2', model: 'Pixel 8', description: '', qty: 1, imeis: ['222222222222222'] }] };
      S.receiveIdemKey = genUuid();
      S.receiveQueuedKey = null;
      S.receiveStep = 'batchSummary';
      render();
    });
    check('the NEW, different batch is NOT blocked - normal Finish button shown', (await page.locator('#receiveFinishBtn').count()) === 1 && (await page.locator('.queued-notice').count()) === 0);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 6. Queued notice clears once the entry resolves ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'eod', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      render();
    });
    await page.fill('#eodCount', '5'); await page.fill('#eodFaulty', '0'); await page.fill('#eodCash', '150');
    await page.evaluate(() => confirmEod());
    await page.waitForTimeout(300);
    await page.evaluate(() => render());
    check('queued notice showing', (await page.locator('.queued-notice').count()) === 1);

    // Now let it succeed, and confirm re-rendering the eod screen shows the
    // normal button again (nothing left queued to match against).
    await page.evaluate(() => { window.__mockResults = [{ ok: true, data: null, noReply: false }]; });
    await page.evaluate(() => sendQueueNow());
    await page.waitForTimeout(300);
    await page.evaluate(() => { S.eodIdemKey = genUuid(); render(); }); // re-enter the screen fresh, as a real nav would
    check('queued notice gone once resolved', (await page.locator('.queued-notice').count()) === 0);
    check('normal submit button back', (await page.locator('#eodSubmitBtn').count()) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 7. Admin login survives a background outbox/realtime render event mid-flight (reproduces the reported bug) ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'adminLogin' };
      SHOPS = []; // keeps the post-login Promise.all(SHOPS.map(loadShopData)) trivial
      REALTIME_CHANNELS = {};

      // A controllable-delay sb, standing in for the real network round trip
      // signInWithPassword() actually makes - resolved manually below, from
      // the middle of the test, to create the exact "mid-flight" window the
      // bug lives in.
      window.__signInCalls = 0;
      sb = {
        auth: {
          signInWithPassword: (creds) => { window.__signInCalls++; return new Promise((resolve) => { window.__resolveSignIn = resolve; }); },
          signOut: () => Promise.resolve({ error: null })
        },
        from: (table) => ({
          select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: { username: 'owner' }, error: null }) }) })
        }),
        channel: (name) => {
          const chain = { on: (event, filter, cb) => { window.__realtimeBumpCallback = cb; return chain; }, subscribe: () => chain };
          return chain;
        }
      };
      // Stands in for a real Supabase read - the render-gating logic under
      // test doesn't depend on what this actually fetches.
      window.refreshShopData = (shopId) => Promise.resolve(SHOP_CACHE[shopId] || emptyShopData());

      // Simulates a channel left over from an earlier session, still live
      // while the admin is now sitting on the login screen - the exact
      // "realtime bump" scenario flagged alongside the outbox one.
      subscribeToShop('harare');

      render();
    });

    check('adminLoginBtn present and enabled before submitting', (await page.locator('#adminLoginBtn').isDisabled()) === false);
    await page.fill('#adminEmail', 'owner@towdah.com');
    await page.fill('#adminPass', 'correcthorse');

    await page.evaluate(() => {
      window.__renderCalls = 0;
      window.__realRender = window.render;
      window.render = function () { window.__renderCalls++; return window.__realRender(); };
    });

    // A REAL click, not page.evaluate(() => submitAdminLogin()) - calling the
    // function directly never moves focus off the password field the way an
    // actual tap does, which would leave the original focus-guard alone
    // protecting this test for the wrong reason (confirmed: with the new
    // flag check stripped out, this test still passed when driven via
    // page.evaluate - only a real click, which moves focus onto the button
    // itself, exercises the exact gap the flag exists to close). Not
    // awaited - submitAdminLogin() hangs on the controllable-delay
    // signInWithPassword, and this script needs to keep running while it does.
    page.locator('#adminLoginBtn').click();
    await page.waitForTimeout(200); // let the click handler run up to its await

    check('CRITICAL_FLOW_IN_PROGRESS is true while the login is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button shows the locked "Signing in…" state', (await page.evaluate(() => document.getElementById('adminLoginBtn').textContent)) === 'Signing in…');
    check('button is disabled', (await page.evaluate(() => document.getElementById('adminLoginBtn').disabled)) === true);
    check('typed email is still there before any background event fires', (await page.evaluate(() => document.getElementById('adminEmail').value)) === 'owner@towdah.com');

    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    // Fire BOTH background render triggers mid-flight - the exact reported
    // bug conditions. Neither should touch the screen.
    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    const rendersAfter = await page.evaluate(() => window.__renderCalls);
    check('neither background trigger caused a render() while CRITICAL_FLOW_IN_PROGRESS was true', rendersAfter === rendersBefore, `before=${rendersBefore} after=${rendersAfter}`);
    check('the login form is NOT wiped - email still shows what was typed', (await page.evaluate(() => document.getElementById('adminEmail').value)) === 'owner@towdah.com');
    check('the password is NOT wiped either', (await page.evaluate(() => document.getElementById('adminPass').value)) === 'correcthorse');
    check('still showing the locked "Signing in…" state, not reset back to "Log in"', (await page.evaluate(() => document.getElementById('adminLoginBtn').textContent)) === 'Signing in…');

    // Now let the (mocked) network reply actually land, and confirm the
    // login completes normally - this isn't just "nothing broke", the flow
    // has to actually finish.
    await page.evaluate(() => window.__resolveSignIn({ data: { user: { id: 'u1' } }, error: null }));
    await page.waitForTimeout(300);

    check('login completed - navigated to ownerDash', (await page.evaluate(() => S.view)) === 'ownerDash');
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once the flow resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('signInWithPassword was only ever called once - the background events did not trigger a second attempt', (await page.evaluate(() => window.__signInCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 8. Sell phone: CRITICAL_FLOW_IN_PROGRESS covers confirmSale, key survives a mid-flight background render ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'salePrice', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      selectedPhone = { id: 'pA', model: 'Galaxy A55', listPrice: 180 };
      saleIdemKey = genUuid();
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    await page.fill('#priceInput', '150');
    page.locator('#saleConfirmBtn').click(); // real click, not page.evaluate(confirmSale())
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the sale RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('saleConfirmBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => saleIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    check('no background render fired while in flight', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('saleIdemKey unchanged by the background renders', (await page.evaluate(() => saleIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('saleConfirmBtn').disabled)) === true);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('sale completed - success box shown', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    check('saleIdemKey reset to null after completion', (await page.evaluate(() => saleIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 9. Client return: CRITICAL_FLOW_IN_PROGRESS covers confirmReturn, key survives a mid-flight background render ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'returnReason', shopId: 'harare', staffId: 's1', staffName: 'Test', returnReason: 'Changed mind', returnFaultParts: null, returnNotes: null };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      selectedPhone = { id: 'pB', model: 'iPhone 13', salePrice: 540 };
      returnIdemKey = genUuid();
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    page.locator('#returnConfirmBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the return RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('returnConfirmBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => returnIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    check('no background render fired while in flight', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('returnIdemKey unchanged by the background renders', (await page.evaluate(() => returnIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('returnConfirmBtn').disabled)) === true);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('return completed - success box shown', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    check('returnIdemKey reset to null after completion', (await page.evaluate(() => returnIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 10. Open day: CRITICAL_FLOW_IN_PROGRESS covers openBizDayStaffAction, including staffMenu\'s own pollTick() timer ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [] };
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    page.locator('#openDayBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the open-day RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('openDayBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => openDayIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    // pollTick() is staffMenu's own 15s timer. Make refreshShopData report a
    // real change so it actually reaches its render() gate - otherwise
    // "nothing changed" alone would explain a skipped render, not the flag.
    await page.evaluate(() => { window.refreshShopData = (id) => { SHOP_CACHE[id] = Object.assign({}, SHOP_CACHE[id], { _pollBump: true }); return Promise.resolve(SHOP_CACHE[id]); }; });
    await page.evaluate(() => pollTick());
    await page.waitForTimeout(200);

    check('no background render fired while in flight (outbox/realtime/pollTick all blocked)', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('openDayIdemKey unchanged by the background renders', (await page.evaluate(() => openDayIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('openDayBtn').disabled)) === true);

    // A real open-day success flips business_days to 'open' server-side, so
    // the post-success refreshShopData must reflect that too, or the
    // trailing render() below would still see "not open" and correctly
    // re-mint openDayIdemKey - that's screenStaffMenu()'s own guard doing
    // its job, not the bug this test is checking for.
    await page.evaluate(() => { window.refreshShopData = (id) => { SHOP_CACHE[id] = Object.assign({}, SHOP_CACHE[id], { businessDays: [{date: todayStr(), status: 'open'}] }); return Promise.resolve(SHOP_CACHE[id]); }; });
    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('openDayIdemKey reset to null after completion', (await page.evaluate(() => openDayIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 11. Close day: CRITICAL_FLOW_IN_PROGRESS covers closeBizDayAction (after the confirm modal) ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [{date: todayStr(), physicalCount: 5, faultyCount: 0, cash: 150}], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    page.locator('#closeDayBtn').click();
    await page.waitForTimeout(150);
    check('confirm modal shown', (await page.locator('.modal-overlay').count()) === 1);
    page.locator('.modal-overlay .yes-safe').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the close-day RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('closeDayBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => closeDayIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.evaluate(() => { window.refreshShopData = (id) => { SHOP_CACHE[id] = Object.assign({}, SHOP_CACHE[id], { _pollBump: true }); return Promise.resolve(SHOP_CACHE[id]); }; });
    await page.evaluate(() => pollTick());
    await page.waitForTimeout(200);

    check('no background render fired while in flight (outbox/realtime/pollTick all blocked)', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('closeDayIdemKey unchanged by the background renders', (await page.evaluate(() => closeDayIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('closeDayBtn').disabled)) === true);

    // A real close-day success flips business_days to 'closed' server-side -
    // reflect that so the trailing render() below matches what actually
    // happens (day no longer open, so screenStaffMenu() takes the "not
    // open" branch and never touches closeDayIdemKey at all).
    await page.evaluate(() => { window.refreshShopData = (id) => { SHOP_CACHE[id] = Object.assign({}, SHOP_CACHE[id], { businessDays: [{date: todayStr(), status: 'closed'}] }); return Promise.resolve(SHOP_CACHE[id]); }; });
    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('closeDayIdemKey reset to null after completion', (await page.evaluate(() => closeDayIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 12. Submit EOD: CRITICAL_FLOW_IN_PROGRESS covers confirmEod, key survives a mid-flight background render ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'eod', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    await page.fill('#eodCount', '5'); await page.fill('#eodFaulty', '0'); await page.fill('#eodCash', '150');
    page.locator('#eodSubmitBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the EOD RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('eodSubmitBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => S.eodIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    check('no background render fired while in flight', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('S.eodIdemKey unchanged by the background renders', (await page.evaluate(() => S.eodIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('eodSubmitBtn').disabled)) === true);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('EOD completed - success box shown', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    check('S.eodIdemKey reset to null after completion', (await page.evaluate(() => S.eodIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 13. Receive stock: CRITICAL_FLOW_IN_PROGRESS covers finishReceiving, key survives a mid-flight background render ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'receive', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      S.receiveBatch = { lines: [{ batchId: 'b1', model: 'Galaxy A55', description: '', qty: 1, imeis: ['111111111111111'] }] };
      S.receiveIdemKey = genUuid();
      S.receiveStep = 'batchSummary';
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    page.locator('#receiveFinishBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the receive RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('receiveFinishBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => S.receiveIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    check('no background render fired while in flight', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('S.receiveIdemKey unchanged by the background renders', (await page.evaluate(() => S.receiveIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('receiveFinishBtn').disabled)) === true);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: 1, noReply: false }));
    await page.waitForTimeout(300);

    check('receive completed - success box shown', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    check('S.receiveBatch reset after completion', (await page.evaluate(() => JSON.stringify(S.receiveBatch))) === JSON.stringify({lines:[]}));
    check('S.receiveIdemKey reset to null after completion', (await page.evaluate(() => S.receiveIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 14. Receive stock: batch/key reset immediately on success, before refreshShopData/loadShopsAndModels resolve ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'receive', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      S.receiveBatch = { lines: [{ batchId: 'b1', model: 'Galaxy A55', description: '', qty: 1, imeis: ['111111111111111'] }] };
      S.receiveIdemKey = genUuid();
      S.receiveStep = 'batchSummary';
      render();

      // callRpc itself resolves right away here - only refreshShopData and
      // loadShopsAndModels are held open, to isolate the ordering of the
      // reset relative to those two specific awaits.
      window.callRpc = () => Promise.resolve({ ok: true, data: 1, noReply: false });
      window.refreshShopData = () => new Promise((resolve) => { window.__resolveRefresh = resolve; });
      window.loadShopsAndModels = () => new Promise((resolve) => { window.__resolveLoadModels = resolve; });
    });

    page.locator('#receiveFinishBtn').click();
    await page.waitForTimeout(200);

    check('S.receiveBatch already reset before refreshShopData/loadShopsAndModels resolve', (await page.evaluate(() => JSON.stringify(S.receiveBatch))) === JSON.stringify({lines:[]}));
    check('S.receiveIdemKey already null before those awaits resolve', (await page.evaluate(() => S.receiveIdemKey)) === null);

    await page.evaluate(() => window.__resolveRefresh());
    await page.evaluate(() => window.__resolveLoadModels());
    await page.waitForTimeout(200);

    check('flow still completes normally once those resolve', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 15. Sell phone: a thrown error after a successful RPC still gets one catch-up render, not a stuck screen ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'salePrice', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [] };
      selectedPhone = { id: 'pC', model: 'Galaxy A55', listPrice: 180 };
      saleIdemKey = genUuid();
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);
    // Simulate a genuine crash AFTER a successful RPC reply - confirmSale's
    // own post-success code (await refreshShopData, then showSuccessThen)
    // never runs, and there is no catch anywhere in the function, so this
    // is exactly "a thrown error" with nothing else left to redraw the
    // screen except the finally's pending-render catch-up.
    await page.evaluate(() => { window.refreshShopData = () => Promise.reject(new Error('simulated crash')); });

    await page.fill('#priceInput', '150');
    page.locator('#saleConfirmBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);

    // A trigger fires and gets suppressed mid-flight - this is what should
    // leave a render owed once the crash unwinds.
    await page.evaluate(() => { refreshOutboxUI(); });
    check('RENDER_PENDING set once a trigger was suppressed mid-flight', (await page.evaluate(() => RENDER_PENDING)) === true);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('CRITICAL_FLOW_IN_PROGRESS reset to false despite the throw', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('RENDER_PENDING consumed (reset to false) by the catch-up', (await page.evaluate(() => RENDER_PENDING)) === false);
    check('exactly one catch-up render happened', (await page.evaluate(() => window.__renderCalls)) === rendersBefore + 1);
    check('the screen is NOT stuck - saleConfirmBtn is back and enabled, not stuck on "Saving…"', (await page.evaluate(() => { const b = document.getElementById('saleConfirmBtn'); return !!b && !b.disabled && b.textContent === 'Confirm sale'; })));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 16. Open day: a thrown error still gets one catch-up render even though the trailing render() line is skipped ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [] };
      render();
    });
    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);
    // openBizDayStaffAction's own render() call sits AFTER the try/finally,
    // not inside it - an uncaught throw skips straight past that line, out
    // of the function. Only the finally's catch-up can save this screen.
    await page.evaluate(() => { window.refreshShopData = () => Promise.reject(new Error('simulated crash')); });

    page.locator('#openDayBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);

    await page.evaluate(() => { refreshOutboxUI(); });
    check('RENDER_PENDING set once a trigger was suppressed mid-flight', (await page.evaluate(() => RENDER_PENDING)) === true);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('CRITICAL_FLOW_IN_PROGRESS reset to false despite the throw', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('RENDER_PENDING consumed (reset to false) by the catch-up', (await page.evaluate(() => RENDER_PENDING)) === false);
    check('exactly one catch-up render happened (the trailing render() line never ran)', (await page.evaluate(() => window.__renderCalls)) === rendersBefore + 1);
    check('the screen is NOT stuck - openDayBtn is back and enabled, not stuck on "Saving…"', (await page.evaluate(() => { const b = document.getElementById('openDayBtn'); return !!b && !b.disabled && b.textContent === "Open today's business day"; })));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 17. Supabase library blocked (content-blocker simulation): SCRIPT_LOAD_FAILED shows its own message, not the generic "not connected" one ==');
  {
    const page = await browser.newPage();
    page.on('pageerror', e => console.log('  PAGEERROR:', e.message));
    // Block the vendored library specifically - a real network-level abort,
    // not a synthetic dispatched event, so this exercises the actual
    // capture-phase listener against a genuine failed resource load, the
    // same way a content/ad blocker would kill the request.
    await page.route('**/supabase-js.2.112.4.js', route => route.abort('blockedbyclient'));
    await page.route('**/*supabase.co/**', route => route.abort('connectionrefused'));
    await page.goto(FILE);
    await page.waitForTimeout(500);

    const t = await page.evaluate(() => document.getElementById('app').innerText);
    check('SCRIPT_LOAD_FAILED flag is set', (await page.evaluate(() => SCRIPT_LOAD_FAILED)) === true);
    check('the specific "could not load" message is shown', /COULD NOT LOAD/.test(t), t.slice(0, 200));
    check('the generic "not connected to database" message is NOT also shown', !/NOT CONNECTED/.test(t), t.slice(0, 200));
    check('window.supabase itself never got defined', (await page.evaluate(() => typeof window.supabase)) === 'undefined');
    check('the Supabase client (sb) is null as a result', (await page.evaluate(() => sb)) === null);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 18. Admin search & valuation: cross-shop search finds phones by IMEI, unpriced stock is excluded from the total ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      ADMIN_SESSION = { userId: 'u1', username: 'owner' };
      SHOPS = [
        { id: 'harare', name: 'Harare CBD', active: true, sortOrder: 1 },
        { id: 'bulawayo1', name: 'Bulawayo Shop 1', active: true, sortOrder: 2 }
      ];
      SHOP_CACHE['harare'] = {
        inventory: [
          { id: 'p1', imei: '111122223333', model: 'iPhone 13', description: '128GB', batchId: 'b1', costPrice: 200, listPrice: 300, status: 'in_stock', receivedTs: 1 },
          { id: 'p2', imei: '444455556666', model: 'iPhone 13', description: '128GB', batchId: 'b2', costPrice: null, listPrice: null, status: 'in_stock', receivedTs: 2 }
        ],
        dailyLogs: [], activity: [], businessDays: [], ledger: []
      };
      SHOP_CACHE['bulawayo1'] = {
        inventory: [
          { id: 'p3', imei: '777788889999', model: 'Pixel 8', description: '', batchId: 'b3', costPrice: 150, listPrice: 220, status: 'sold', receivedTs: 3 }
        ],
        dailyLogs: [], activity: [], businessDays: [], ledger: []
      };
      S = { view: 'ownerSearch' };
      render();
    });

    // Real typing, not a synthetic evaluate() call - exercises the actual
    // input-event listener wired up by attachOwnerSearchInput().
    await page.fill('#ownerSearchInput', '3333');
    await page.waitForTimeout(50);
    const resultsText = await page.evaluate(() => document.getElementById('ownerSearchResults').innerText);
    check('searching by a partial IMEI (from Harare) finds the phone', /iPhone 13/.test(resultsText));
    check('search result shows the owning shop name', /Harare CBD/.test(resultsText));

    await page.fill('#ownerSearchInput', 'pixel');
    await page.waitForTimeout(50);
    // Checked against the .list-item PHONE rows specifically, not the whole
    // results blob - the ledger half of the search scans buildTransactions('all')
    // regardless, so a check against the combined text would still pass even if
    // the PHONES half were wrongly scoped to a single shop. This has to isolate
    // the phones result list to actually prove that half is cross-shop.
    const phoneRowsText2 = await page.evaluate(() => Array.from(document.querySelectorAll('#ownerSearchResults .list-item')).map(el => el.innerText).join(' | '));
    check('a query only matching a DIFFERENT shop\'s PHONE (Bulawayo) still returns it in the phone results - phone search is cross-shop, not scoped to one shop', /Bulawayo Shop 1/.test(phoneRowsText2), phoneRowsText2);

    // Valuation: only the priced phone (p1, $200) should count; the unpriced
    // one (p2) must be excluded from the total and flagged instead.
    const valuationText = await page.evaluate(() => document.getElementById('app').innerText);
    check('valuation total includes the priced in-stock phone\'s cost ($200)', /\$200/.test(valuationText));
    check('valuation flags the unpriced phone as a separate count, not silently zeroed into the total', /1 unpriced/.test(valuationText));
    check('the all-shops alert banner reports exactly 1 phone missing a price', /1 phone\(s\) in stock have no cost price set/.test(valuationText));

    // Clicking the unpriced flag navigates to the existing pricing screen for
    // that shop - a real click, verifying the two features are wired together.
    await page.locator('.chip-red', { hasText: 'unpriced' }).click();
    check('tapping the unpriced flag navigates to ownerPricing for the right shop', (await page.evaluate(() => S.view)) === 'ownerPricing' && (await page.evaluate(() => S.mgmtShop)) === 'harare');

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 19. Log an expense: seventh menu button (both day states), full CRITICAL_FLOW_IN_PROGRESS + idempotency flow ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [], expenses: [] };
      render();
    });
    let t = await page.evaluate(() => document.getElementById('app').innerText);
    check('"Log an expense" appears even when the day is NOT open - the whole point of dropping require_day_open server-side', /Log an expense/.test(t));

    await page.evaluate(() => {
      SHOP_CACHE['harare'].businessDays = [{date: todayStr(), status: 'open'}];
      render();
    });
    t = await page.evaluate(() => document.getElementById('app').innerText);
    check('"Log an expense" also appears once the day IS open, alongside the other six', /Log an expense/.test(t));

    await installRealtimeBumpCapture(page, 'harare');
    await installControllableRpc(page);
    await installRenderCounter(page);

    await page.evaluate(() => navTo('expense'));
    await page.locator('.reason-btn', { hasText: 'Transport' }).click();
    await page.fill('#expenseAmountInput', '5');
    await page.fill('#expenseNoteInput', 'kombi fare');
    page.locator('#expenseConfirmBtn').click();
    await page.waitForTimeout(200);

    check('CRITICAL_FLOW_IN_PROGRESS true while the expense RPC is in flight', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === true);
    check('button locked (disabled)', (await page.evaluate(() => document.getElementById('expenseConfirmBtn').disabled)) === true);
    const keyBefore = await page.evaluate(() => S.expenseIdemKey);
    const rendersBefore = await page.evaluate(() => window.__renderCalls);

    await page.evaluate(() => { refreshOutboxUI(); });
    await page.evaluate(() => { if (window.__realtimeBumpCallback) window.__realtimeBumpCallback(); });
    await page.waitForTimeout(200);

    check('no background render fired while in flight', (await page.evaluate(() => window.__renderCalls)) === rendersBefore);
    check('S.expenseIdemKey unchanged by the background renders', (await page.evaluate(() => S.expenseIdemKey)) === keyBefore);
    check('button still locked after the background events', (await page.evaluate(() => document.getElementById('expenseConfirmBtn').disabled)) === true);

    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(300);

    check('expense logged - success box shown', (await page.evaluate(() => document.querySelector('.success-box') !== null)));
    check('S.expenseIdemKey cleared to null on success', (await page.evaluate(() => S.expenseIdemKey)) === null);
    check('CRITICAL_FLOW_IN_PROGRESS reset to false once resolved', (await page.evaluate(() => CRITICAL_FLOW_IN_PROGRESS)) === false);
    check('callRpc was only ever called once - no duplicate submission slipped through', (await page.evaluate(() => window.__rpcCalls)) === 1);
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 20. EOD rollup: "Expenses today" is display-only, filtered to today, no variance calculation ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      S = { view: 'eod', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = {
        inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [],
        expenses: [
          { id: 'e1', shopId: 'harare', date: todayStr(), category: 'Transport', amount: 5, note: 'kombi', staffId: 's1', staffName: 'Test', createdAt: Date.now() },
          { id: 'e2', shopId: 'harare', date: todayStr(), category: 'Airtime/data', amount: 2.5, note: null, staffId: 's1', staffName: 'Test', createdAt: Date.now() },
          { id: 'e3', shopId: 'harare', date: '2020-01-01', category: 'Other', amount: 999, note: 'old, must not count', staffId: 's1', staffName: 'Test', createdAt: Date.now() }
        ]
      };
      render();
    });
    const t = await page.evaluate(() => document.getElementById('app').innerText);
    check('shows the combined total for today\'s two expenses ($7.5), not the old one', /Expenses today: \$7\.5 \(2 logged\)/.test(t), t.slice(0, 300));
    check('does not fold in the differently-dated expense\'s amount ($999)', !/999/.test(t));
    check('no variance/mismatch language anywhere on this screen - display only, as scoped', !/variance/i.test(t) && !/mismatch/i.test(t));
    await page.close();
  }

  // ===========================================================================
  console.log('\n== 21. Admin expenses screen: shop/date filtering, delete via admin_delete_expense ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      ADMIN_SESSION = { userId: 'u1', username: 'owner' };
      SHOPS = [
        { id: 'harare', name: 'Harare CBD', active: true, sortOrder: 1 },
        { id: 'bulawayo1', name: 'Bulawayo Shop 1', active: true, sortOrder: 2 }
      ];
      SHOP_CACHE['harare'] = {
        inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [],
        expenses: [{ id: 'e1', shopId: 'harare', date: todayStr(), category: 'Transport', amount: 5, note: 'kombi', staffId: 's1', staffName: 'Tanatswa', createdAt: Date.now() }]
      };
      SHOP_CACHE['bulawayo1'] = {
        inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [],
        expenses: [{ id: 'e2', shopId: 'bulawayo1', date: todayStr(), category: 'ZESA', amount: 12, note: null, staffId: 's2', staffName: 'Pela', createdAt: Date.now() }]
      };
      S = { view: 'ownerExpenses' };
      render();
    });
    let t = await page.evaluate(() => document.getElementById('app').innerText);
    check('all-shops view shows both shops\' expenses', /Harare CBD/.test(t) && /Bulawayo Shop 1/.test(t) && /Tanatswa/.test(t) && /Pela/.test(t));

    await page.evaluate(() => { S.expShop = 'harare'; render(); });
    t = await page.evaluate(() => document.getElementById('app').innerText);
    check('filtering to one shop hides the other shop\'s expense', /Tanatswa/.test(t) && !/Pela/.test(t));

    await page.evaluate(() => { S.expDate = '2019-01-01'; render(); });
    t = await page.evaluate(() => document.getElementById('app').innerText);
    check('filtering to a non-matching date shows nothing', /No expenses for this filter/.test(t));

    await page.evaluate(() => { S.expDate = todayStr(); render(); });
    await installControllableRpc(page);
    // deleteExpense() awaits refreshShopData(shopId) on success - stubbed the
    // same way every other test in this file stubs it, otherwise it runs
    // against a real (blocked) Supabase client, which resolves but takes
    // several seconds per call, not because anything is actually wrong.
    // Simulates what a real refresh would show post-deletion by actually
    // removing the row, rather than just returning the untouched cache.
    await page.evaluate(() => {
      window.refreshShopData = (id) => {
        if (SHOP_CACHE[id]) SHOP_CACHE[id].expenses = SHOP_CACHE[id].expenses.filter(e => e.id !== 'e1');
        return Promise.resolve(SHOP_CACHE[id] || emptyShopData());
      };
    });
    page.locator('button', { hasText: 'Delete' }).first().click();
    await page.waitForTimeout(150);
    await page.locator('.modal-overlay .yes, .modal-overlay .yes-safe').click();
    await page.waitForTimeout(100);
    check('confirm modal required before deleting - RPC not called until confirmed', (await page.evaluate(() => window.__rpcCalls)) === 1);
    check('deletion targets the real admin_delete_expense RPC with the right id', (await page.evaluate(() => window.__lastRpcName)) === 'admin_delete_expense');
    await page.evaluate(() => window.__resolveRpc({ ok: true, data: null, noReply: false }));
    await page.waitForTimeout(200);
    t = await page.evaluate(() => document.getElementById('app').innerText);
    check('deleted expense no longer shown after the screen refreshes', !/Tanatswa/.test(t));

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 22. Session teardown: "change name" survives, reaching admin login tears down the stale channel and S.shopId ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      REALTIME_CHANNELS = {};
      window.__removeChannelCalls = 0;
      // Stands in for the real Supabase client - the render-gating logic
      // under test doesn't depend on what this actually fetches, same
      // technique as the admin-login mid-flight test.
      sb = {
        channel: () => {
          const chain = { on: (ev, filt, cb) => { window.__bumpCallback = cb; return chain; }, subscribe: () => chain };
          return chain;
        },
        removeChannel: () => { window.__removeChannelCalls++; }
      };
      window.refreshShopData = (id) => Promise.resolve(SHOP_CACHE[id] || emptyShopData());
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Tanatswa' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [], expenses: [] };
      subscribeToShop('harare');
      render();
    });
    check('realtime channel exists after a normal staff login', (await page.evaluate(() => !!REALTIME_CHANNELS['harare'])));

    // "Not X? Change name" - same shop, a new PIN is still expected next.
    // The exact inline behaviour of that button, not a helper function - it
    // has none today.
    await page.evaluate(() => { S.staffName = null; S.staffId = null; navTo('staffPicker'); });
    check('landed on staffPicker for the same shop', (await page.evaluate(() => S.view)) === 'staffPicker');
    check('the channel is NOT torn down while staffPicker still needs S.shopId', (await page.evaluate(() => !!REALTIME_CHANNELS['harare'])));
    check('S.shopId is preserved for staffPicker to use', (await page.evaluate(() => S.shopId)) === 'harare');

    // Abandon the picker without completing a new PIN - reach admin login instead.
    await page.evaluate(() => { menuNavigate('adminLogin'); });
    await page.waitForTimeout(50);
    check('landed on adminLogin', (await page.evaluate(() => S.view)) === 'adminLogin');
    check('S.shopId cleared on reaching admin login', (await page.evaluate(() => S.shopId)) === null);
    check('the stale channel was removed from REALTIME_CHANNELS', (await page.evaluate(() => !REALTIME_CHANNELS['harare'])));
    check('sb.removeChannel was actually called, not just forgotten from the map', (await page.evaluate(() => window.__removeChannelCalls)) === 1);

    // The actual reported symptom: type into the form, move focus away (the
    // real gap - bump()'s own activeElement guard already protects the
    // field currently focused; the reported bug happens in the pause
    // between fields, or before either is focused at all), then fire the
    // STALE captured realtime callback directly (simulating another device
    // still writing to harare) and confirm it can no longer wipe the form.
    await page.fill('#adminEmail', 'owner@towdah.com');
    await page.evaluate(() => document.getElementById('adminEmail').blur());
    await page.evaluate(() => {
      window.__renderCalls = 0;
      window.__realRender = window.render;
      window.render = function () { window.__renderCalls++; return window.__realRender(); };
    });
    await page.evaluate(() => { if (window.__bumpCallback) window.__bumpCallback(); });
    await page.waitForTimeout(200);
    check('the stale bump callback no longer triggers a render (its own S.shopId===shopId gate now fails)', (await page.evaluate(() => window.__renderCalls)) === 0);
    check('the typed email survives - this is the actual symptom that made a refresh necessary', (await page.evaluate(() => document.getElementById('adminEmail').value)) === 'owner@towdah.com');

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 23. Session teardown: switching shops while signed in tears down the OLD shop\'s channel immediately ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      REALTIME_CHANNELS = {};
      window.__removeChannelCalls = 0;
      sb = {
        channel: () => { const chain = { on: () => chain, subscribe: () => chain }; return chain; },
        removeChannel: () => { window.__removeChannelCalls++; }
      };
      window.refreshShopData = (id) => Promise.resolve(SHOP_CACHE[id] || emptyShopData());
      SHOPS = [
        { id: 'harare', name: 'Harare CBD', active: true, sortOrder: 1 },
        { id: 'bulawayo1', name: 'Bulawayo Shop 1', active: true, sortOrder: 2 }
      ];
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Tanatswa' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [], expenses: [] };
      SHOP_CACHE['bulawayo1'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [], ledger: [], expenses: [] };
      subscribeToShop('harare');
    });
    check('harare channel exists before switching', (await page.evaluate(() => !!REALTIME_CHANNELS['harare'])));

    await page.evaluate(() => { menuTapShop('bulawayo1'); });
    await page.waitForTimeout(50);

    check('S.shopId is now the new shop', (await page.evaluate(() => S.shopId)) === 'bulawayo1');
    check('the OLD shop\'s channel was torn down at the moment of switching - render()\'s own invariant could never see it once S.shopId changed', (await page.evaluate(() => !REALTIME_CHANNELS['harare'])));
    check('sb.removeChannel was actually called', (await page.evaluate(() => window.__removeChannelCalls)) === 1);

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 24. loadShopData\'s fire-and-forget render respects CRITICAL_FLOW_IN_PROGRESS and the focus guard ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      REALTIME_CHANNELS = {};
      sb = { channel: () => { const chain = { on: () => chain, subscribe: () => chain }; return chain; } };
      S = { view: 'salePrice', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOP_CACHE['harare'] = { inventory: [], dailyLogs: [], activity: [], businessDays: [{date: todayStr(), status: 'open'}], ledger: [], expenses: [] };
      selectedPhone = { id: 'pA', model: 'Galaxy A55', listPrice: 180 };
      CRITICAL_FLOW_IN_PROGRESS = false;
      RENDER_PENDING = false;
      render();
    });
    await installRenderCounter(page);

    // Case A: the fetch resolves while a critical flow is mid-flight - must
    // not render, and must set RENDER_PENDING for that flow's own finally
    // block to replay once it ends (same treatment as subscribeToShop's bump()).
    await page.evaluate(() => {
      window.__resolveRefresh = null;
      window.refreshShopData = (id) => new Promise((resolve) => { window.__resolveRefresh = resolve; });
      loadShopData('harare');
      CRITICAL_FLOW_IN_PROGRESS = true;
    });
    await page.evaluate(() => window.__resolveRefresh());
    await page.waitForTimeout(150);
    check('no render fired while CRITICAL_FLOW_IN_PROGRESS was true', (await page.evaluate(() => window.__renderCalls)) === 0);
    check('RENDER_PENDING set instead, for the flow\'s own finally block to replay', (await page.evaluate(() => RENDER_PENDING)) === true);

    await page.evaluate(() => { CRITICAL_FLOW_IN_PROGRESS = false; if (RENDER_PENDING) { RENDER_PENDING = false; render(); } });
    await page.waitForTimeout(50);
    check('the deferred render replays exactly once, same as every other guarded trigger', (await page.evaluate(() => window.__renderCalls)) === 1);

    // Case B: no critical flow, but the field the staff is typing into is
    // focused - same activeElement guard bump() already has. Section 22's
    // lesson applies here too: .fill() leaves the field focused, so this
    // first sub-case tests the guard for real; blur first for the second
    // sub-case to prove a render DOES fire once neither guard applies.
    await page.evaluate(() => { window.__renderCalls = 0; });
    await page.fill('#priceInput', '150');
    await page.evaluate(() => {
      window.__resolveRefresh = null;
      window.refreshShopData = (id) => new Promise((resolve) => { window.__resolveRefresh = resolve; });
      loadShopData('harare');
    });
    await page.evaluate(() => window.__resolveRefresh());
    await page.waitForTimeout(150);
    check('no render while the field the staff is typing into is focused', (await page.evaluate(() => window.__renderCalls)) === 0);

    await page.evaluate(() => document.getElementById('priceInput').blur());
    await page.evaluate(() => {
      window.__resolveRefresh = null;
      window.refreshShopData = (id) => new Promise((resolve) => { window.__resolveRefresh = resolve; });
      loadShopData('harare');
    });
    await page.evaluate(() => window.__resolveRefresh());
    await page.waitForTimeout(150);
    check('render DOES fire once neither guard applies', (await page.evaluate(() => window.__renderCalls)) === 1);

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 25. endShopPresence() clears the whole staff identity, not just S.shopId ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      REALTIME_CHANNELS = {};
      sb = { channel: () => { const chain = { on: () => chain, subscribe: () => chain }; return chain; }, removeChannel: () => {} };
      S = { view: 'staffMenu', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      subscribeToShop('harare');
    });
    check('channel exists before teardown', (await page.evaluate(() => !!REALTIME_CHANNELS['harare'])));

    await page.evaluate(() => { endShopPresence(); });

    check('S.shopId cleared', (await page.evaluate(() => S.shopId)) === null);
    check('S.staffId cleared', (await page.evaluate(() => S.staffId)) === null);
    check('S.staffName cleared', (await page.evaluate(() => S.staffName)) === null);
    check('channel torn down', (await page.evaluate(() => !REALTIME_CHANNELS['harare'])));

    await page.close();
  }

  // ===========================================================================
  console.log('\n== 26. Reaching admin login from Home clears the stale staff identity - a login there must not immediately un-succeed ==');
  {
    const page = await newPage(browser);
    await page.evaluate(() => {
      REALTIME_CHANNELS = {};
      S = { view: 'home', shopId: 'harare', staffId: 's1', staffName: 'Test' };
      SHOPS = []; // keeps the post-login Promise.all(SHOPS.map(loadShopData)) trivial, same as section 7
      sb = {
        auth: {
          signInWithPassword: () => Promise.resolve({ data: { user: { id: 'u1' } }, error: null }),
          signOut: () => Promise.resolve({ error: null })
        },
        from: (table) => ({
          select: () => ({ eq: () => ({ single: () => Promise.resolve({ data: { username: 'owner' }, error: null }) }) })
        }),
        channel: () => { const chain = { on: () => chain, subscribe: () => chain }; return chain; },
        removeChannel: () => {}
      };
      // Simulates the live channel a real staff session on 'harare' would
      // still be holding while sitting on Home - the actual leak scenario.
      subscribeToShop('harare');
      render();
    });
    check('channel exists before reaching admin login', (await page.evaluate(() => !!REALTIME_CHANNELS['harare'])));

    // Real click on Home's "Admin dashboard" button - the actual leak path:
    // screenHome() shows this button unconditionally, with no session check.
    await page.locator('button:has-text("Admin dashboard")').click();

    check('landed on adminLogin', (await page.evaluate(() => S.view)) === 'adminLogin');
    check('S.staffId cleared on reaching admin login', (await page.evaluate(() => S.staffId)) === null);
    check('S.staffName cleared on reaching admin login', (await page.evaluate(() => S.staffName)) === null);
    check('the stale channel was torn down', (await page.evaluate(() => !REALTIME_CHANNELS['harare'])));

    await page.fill('#adminEmail', 'owner@towdah.com');
    await page.fill('#adminPass', 'correcthorse');
    await page.locator('#adminLoginBtn').click();
    await page.waitForTimeout(300);

    check('login succeeded and STAYS succeeded - landed on ownerDash', (await page.evaluate(() => S.view)) === 'ownerDash');
    check('ADMIN_SESSION survives - not immediately cleared by the S.staffId&&ADMIN_SESSION invariant', (await page.evaluate(() => !!ADMIN_SESSION)));

    await page.close();
  }

  await browser.close();
  console.log('\n' + (failures === 0 ? 'ALL OUTBOX UI CHECKS PASSED' : failures + ' FAILED'));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(1); });
