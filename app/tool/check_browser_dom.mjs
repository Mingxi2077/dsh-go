// Runs the production extraction scripts in Chromium. Requires playwright-core.
// node tool/check_browser_dom.mjs /tmp/browser-scripts.json /path/to/chrome
// BROWSER_AUTOMATION_MODULE may point at an existing playwright-core installation.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';

const modulePath = process.env.BROWSER_AUTOMATION_MODULE;
const {chromium} = await import(modulePath ? pathToFileURL(modulePath).href : 'playwright-core');
const scripts = JSON.parse(await readFile(process.argv[2], 'utf8'));
const browser = await chromium.launch({executablePath: process.argv[3], headless: true});
let passed = 0;
try {
  const page = await browser.newPage();
  await page.route('https://example.com/**', route => route.fulfill({body: '<!doctype html><title>Fixture</title><body></body>', contentType: 'text/html'}));
  await page.goto('https://example.com/article?token=fixture');
  const read = async (selection = false) => JSON.parse(await page.evaluate(scripts[selection ? 'selection' : 'page']));
  const check = async (name, run) => { await run(); console.log(`PASS ${name}`); passed++; };
  await check('visible text excludes controls, hidden content and editable subtrees', async () => {
    await page.setContent(`<title>Fixture</title><body><h1>Public title</h1><p>Readable text</p>
      <input value="SECRET"><textarea>SECRET</textarea><select><option>SECRET</option></select>
      <button>SECRET</button><script>window.fixture='SECRET'</script><div hidden>SECRET</div>
      <div aria-hidden="true">SECRET</div><div style="display:none">SECRET</div>
      <div style="visibility:hidden">SECRET</div><div style="opacity:0">SECRET</div>
      <div style="content-visibility:hidden">SECRET</div><div contenteditable><span>SECRET</span></div>
      <iframe srcdoc="SECRET"></iframe></body>`);
    const result = await read();
    assert.equal(result.text, 'Public title\nReadable text');
    assert.equal(result.url, 'https://example.com/article?token=fixture');
  });
  await check('partial selection spans visible nodes without form or hidden text', async () => {
    await page.setContent('<p id="a">Alpha</p><textarea>SECRET</textarea><div hidden>SECRET</div><p id="b">Omega</p>');
    await page.evaluate(() => {
      const range = document.createRange();
      range.setStart(document.querySelector('#a').firstChild, 2);
      range.setEnd(document.querySelector('#b').firstChild, 3);
      getSelection().removeAllRanges(); getSelection().addRange(range);
    });
    assert.equal((await read(true)).text, 'pha\nOme');
  });
  await check('empty selection stays empty', async () => {
    await page.evaluate(() => getSelection().removeAllRanges());
    assert.equal((await read(true)).text, '');
  });
  for (const attribute of ['contenteditable="true"', 'hidden', 'style="opacity:0"']) {
    await check(`body root exclusion: ${attribute}`, async () => {
      await page.setContent(`<body ${attribute}><p>SECRET</p></body>`);
      assert.equal((await read()).text, '');
    });
  }
  await check('editable ancestor above body is excluded', async () => {
    await page.setContent('<html contenteditable="true"><body><p>SECRET</p></body></html>');
    assert.equal((await read()).text, '');
    await page.evaluate(() => document.documentElement.removeAttribute('contenteditable'));
  });
  await check('oversized text is bounded and marked truncated', async () => {
    await page.setContent(`<p>${'a'.repeat(20000)}</p>`);
    const result = await read();
    assert.equal(result.text.length, 16000); assert.equal(result.truncated, true);
  });
  await check('traversal budget counts rejected elements too', async () => {
    await page.setContent(`<p>Start</p>${'<i hidden>SECRET</i>'.repeat(12001)}<p>Beyond budget</p>`);
    const result = await read();
    assert.equal(result.text, 'Start'); assert.equal(result.truncated, true);
  });
  console.log(`${passed} DOM checks passed`);
} finally {
  await browser.close();
}
