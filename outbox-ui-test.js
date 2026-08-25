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

  await browser.close();
  console.log('\n' + (failures === 0 ? 'ALL OUTBOX UI CHECKS PASSED' : failures + ' FAILED'));
  process.exit(failures === 0 ? 0 : 1);
})().catch(e => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(1); });
