// Frontend behaviour test against a mocked Supabase RPC backend (no real data touched).
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const SITE = process.argv[2];
const SHOTS = process.argv[3];
const results = [];
const ok = (name, cond, extra = '') => { results.push([cond ? 'PASS' : 'FAIL', name, extra]); };

const server = http.createServer((req, res) => {
  const f = req.url === '/' ? 'index.html' : req.url.slice(1).split('?')[0];
  const p = path.join(SITE, f);
  if (!fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  const ext = path.extname(p);
  res.writeHead(200, { 'content-type': { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json', '.png': 'image/png' }[ext] || 'application/octet-stream' });
  res.end(fs.readFileSync(p));
});

(async () => {
  await new Promise(r => server.listen(0, r));
  const base = `http://localhost:${server.address().port}/`;
  const browser = await chromium.launch();

  // ---------- login error handling ----------
  {
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await ctx.newPage();
    const errs = [];
    page.on('pageerror', e => errs.push(String(e)));
    let mode = 'bad';
    await page.route('**/rest/v1/rpc/**', async route => {
      const h = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'content-type': 'application/json' };
      if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers: h });
      if (mode === 'bad') return route.fulfill({ status: 400, headers: h, body: '{"message":"bad"}' });
      if (mode === 'locked') return route.fulfill({ status: 429, headers: h, body: '{"message":"locked"}' });
      return route.fulfill({ status: 400, headers: h, body: '{"message":"badcode"}' });
    });
    await page.goto(base);
    await page.fill('#nm', 'someone'); await page.fill('#pw', 'wrong-pass');
    await page.click('#go'); await page.waitForFunction(() => document.getElementById('err').textContent.length > 0);
    ok('login: wrong password shows friendly message', (await page.textContent('#err')) === 'Wrong name or password', await page.textContent('#err'));
    mode = 'locked'; await page.click('#go');
    await page.waitForFunction(() => document.getElementById('err').textContent.startsWith('Too many'));
    ok('login: lockout (HTTP 429) shows wait message', (await page.textContent('#err')) === 'Too many tries. Wait 10 minutes', await page.textContent('#err'));
    await page.click('#sw'); mode = 'badcode'; await page.fill('#code', 'nope'); await page.click('#go');
    await page.waitForFunction(() => document.getElementById('err').textContent.includes('invite'));
    ok('register: wrong invite code shows message', (await page.textContent('#err')) === 'That invite code is wrong', await page.textContent('#err'));
    ok('login screen: no page errors', errs.length === 0, errs.join(' | '));
    await ctx.close();
  }

  // ---------- main app flows ----------
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', hasTouch: true });
  const page = await ctx.newPage();
  const pageErrors = [], consoleErrors = [];
  page.on('pageerror', e => pageErrors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|net::ERR/.test(m.text())) consoleErrors.push(m.text()); });

  const srv = { msgs: [], nextId: 100, sendCalls: [], askCalls: [], undoCalls: 0, behaviors: [], clears: 0 };
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'content-type': 'application/json' };
  await page.route('**/rest/v1/rpc/**', async route => {
    const req = route.request();
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    const fn = req.url().split('/rpc/')[1];
    const body = req.postDataJSON() || {};
    const json = (o, status = 200) => route.fulfill({ status, headers: cors, body: JSON.stringify(o) });
    switch (fn) {
      case 'lv_login': return json('tok123');
      case 'lv_poll':
        return json({ me: 'u1', users: [{ id: 'u1', name: 'Me', on: true, ty: false }, { id: 'u2', name: 'Star', on: false, ty: false }],
          msgs: srv.msgs.filter(m => m.id > (body.p_last || 0)), reacts: [], epoch: '0', used: [], favs: [], lv: 'v1' });
      case 'lv_getlist': return json('1. First question?\n2. Second question?');
      case 'lv_send': {
        srv.sendCalls.push(body);
        const b = srv.behaviors.shift() || 'ok';
        if (b === 'abort') return route.abort('failed');
        if (typeof b === 'object') return json({ message: b.err }, 400);
        let ex = srv.msgs.find(m => m.cid === body.p_cid && m.uid === 'u1');          // idempotent like the real function
        if (!ex) { ex = { id: srv.nextId++, uid: 'u1', kind: body.p_kind, body: body.p_body, media: null, reply: null, cid: body.p_cid, at: Date.now() }; srv.msgs.push(ex); }
        return json(ex.id);
      }
      case 'lv_ask': {
        srv.askCalls.push(body);
        srv.msgs.push({ id: srv.nextId++, uid: 'u1', kind: 'q', body: body.p_n + '\n' + body.p_q, media: null, reply: null, cid: body.p_cid, at: Date.now() });
        return json(null);
      }
      case 'lv_undo_clear': srv.undoCalls++; return json(3);
      default: return json(null);
    }
  });

  await page.goto(base);
  await page.fill('#nm', 'Me'); await page.fill('#pw', 'password1'); await page.click('#go');
  await page.waitForSelector('#app.on');
  await page.waitForFunction(() => document.getElementById('ps').textContent !== 'Connecting…');
  ok('app: signs in and shows partner status', (await page.textContent('#pn')) === 'Star', await page.textContent('#pn') + ' / ' + await page.textContent('#ps'));

  // T2: normal send includes a client id
  await page.fill('#ti', 'hello there'); await page.press('#ti', 'Enter');
  await page.waitForFunction(() => [...document.querySelectorAll('#msgs .b')].some(b => b.textContent === 'hello there'));
  const c1 = srv.sendCalls[0];
  ok('send: includes retry-safe client id (32 chars)', c1 && typeof c1.p_cid === 'string' && c1.p_cid.length === 32, c1 && c1.p_cid);
  ok('send: kind/body correct', c1.p_kind === 'text' && c1.p_body === 'hello there');

  // T3: transient network failure -> automatic retry with SAME client id, message appears once
  srv.behaviors = ['abort', 'ok'];
  const before = srv.sendCalls.length;
  await page.fill('#ti', 'retry me'); await page.press('#ti', 'Enter');
  await page.waitForFunction(() => [...document.querySelectorAll('#msgs .b')].some(b => b.textContent === 'retry me'), null, { timeout: 8000 });
  const calls3 = srv.sendCalls.slice(before);
  ok('retry: network drop retried automatically (2 attempts)', calls3.length === 2, 'attempts=' + calls3.length);
  ok('retry: both attempts used the same client id', calls3.length === 2 && calls3[0].p_cid === calls3[1].p_cid);
  ok('retry: message shown exactly once', (await page.$$eval('#msgs .b', els => els.filter(b => b.textContent === 'retry me').length)) === 1);

  // T4: total failure -> text restored, retry reuses the same id (no duplicate if first attempt actually arrived)
  srv.behaviors = ['abort', 'abort', 'abort'];
  const before4 = srv.sendCalls.length;
  await page.fill('#ti', 'fail me'); await page.press('#ti', 'Enter');
  await page.waitForFunction(() => document.getElementById('toast').classList.contains('on'), null, { timeout: 9000 });
  const calls4 = srv.sendCalls.slice(before4);
  ok('failure: 3 attempts then gives up', calls4.length === 3, 'attempts=' + calls4.length);
  ok('failure: text restored to the box', (await page.inputValue('#ti')) === 'fail me');
  ok('failure: clear message shown', (await page.textContent('#toast')) === 'Message did not send. Tap send to retry', await page.textContent('#toast'));
  srv.behaviors = [];
  await page.press('#ti', 'Enter');
  await page.waitForFunction(() => [...document.querySelectorAll('#msgs .b')].some(b => b.textContent === 'fail me'), null, { timeout: 8000 });
  const last = srv.sendCalls[srv.sendCalls.length - 1];
  ok('failure: manual retry reuses the original client id', last.p_cid === calls4[0].p_cid);

  // T5: server-side validation error is not retried and shows a clear message
  srv.behaviors = [{ err: 'invalid' }];
  const before5 = srv.sendCalls.length;
  await page.fill('#ti', 'x'.repeat(5)); await page.press('#ti', 'Enter');
  await page.waitForFunction(() => document.getElementById('toast').textContent.startsWith('That message'), null, { timeout: 5000 });
  ok('validation: not retried (1 attempt)', srv.sendCalls.length - before5 === 1);
  ok('validation: friendly text', (await page.textContent('#toast')) === 'That message is empty or too long');

  // T6: question game still works and carries a client id
  await page.fill('#ti', '');
  await page.click("#tabs button[data-t='game']");
  await page.waitForSelector('.gq');
  ok('questions: list renders (2 items)', (await page.$$('.gq')).length === 2);
  await page.click('.gq >> nth=0');
  await page.waitForSelector('.qc');
  ok('questions: ask sends client id', srv.askCalls.length === 1 && srv.askCalls[0].p_cid && srv.askCalls[0].p_n === '1', JSON.stringify(srv.askCalls[0] && { n: srv.askCalls[0].p_n, cid: !!srv.askCalls[0].p_cid }));
  ok('questions: card appears in chat', (await page.textContent('.qc p')).includes('First question?'));

  // T7: undo clear
  await page.click('#gear'); await page.waitForSelector('#sheet.on');
  ok('settings: Undo last clear button present', (await page.textContent('#uc')) === 'Undo last clear');
  await page.click('#uc');
  await page.waitForFunction(() => document.getElementById('toast').textContent.startsWith('Restored'), null, { timeout: 5000 });
  ok('undo clear: calls server and confirms', srv.undoCalls === 1 && (await page.textContent('#toast')) === 'Restored 3 messages', await page.textContent('#toast'));

  // layout checks at phone width
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(SHOTS, 'chat_dark_390.png') });
  const hScroll = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  ok('layout: no horizontal scroll at 390px', !hScroll);
  ok('app: no uncaught page errors', pageErrors.length === 0, pageErrors.join(' | '));
  ok('app: no console errors', consoleErrors.length === 0, consoleErrors.join(' | '));

  await browser.close(); server.close();
  let fail = 0;
  for (const [s, n, e] of results) { if (s === 'FAIL') fail++; console.log(`${s}  ${n}${e ? '   [' + e + ']' : ''}`); }
  console.log(`\n${results.length - fail}/${results.length} passed`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error('TEST RUNNER ERROR', e); process.exit(2); });
