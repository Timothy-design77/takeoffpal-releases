import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {pathToFileURL} from 'node:url';
import {blankPdf} from '../journeys/fixtures/blank.mjs';

const options = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, values) =>
  index % 2 ? pairs : [...pairs, [value.replace(/^--/, ''), values[index + 1]]], []));
assert.ok(options.artifact && options.output, '--artifact and --output are required');
// TakeoffPal is locked until a key is entered: expect open (default) proves the key opens it; locked proves the key is
// refused and the gate holds.
const key = process.env.TAKEOFFPAL_BETA_KEY, expect = process.env.TAKEOFFPAL_EXPECT || 'open';
assert.ok(key, 'TAKEOFFPAL_BETA_KEY is empty: add the TAKEOFFPAL_BETA_KEY secret; without a key TakeoffPal stays locked');
assert.ok(['open', 'locked'].includes(expect), `TAKEOFFPAL_EXPECT must be open or locked, not '${expect}'`);
const mask = text => String(text).replaceAll(key, '***').replace(/#session=[^\s"']+/g, '#session=[redacted]');
const artifact = path.resolve(options.artifact), output = path.resolve(options.output);
fs.mkdirSync(output, {recursive: false});
const home = path.join(output, 'Beta Tester'), applications = path.join(home, 'Applications');
const jobs = path.join(home, 'Jobs'), temporary = path.join(output, 'tmp');
for (const directory of [applications, jobs, temporary]) fs.mkdirSync(directory, {recursive: true});
const result = {artifact: path.basename(artifact), sha256: hash(artifact), platform: process.platform, checks: []};
const helper = path.join(output, 'browser.mjs');
fs.writeFileSync(helper, 'console.log("BETA_BROWSER_URL=" + process.argv[2]);\n');
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
const env = {...process.env, HOME: home, XDG_DATA_HOME: path.join(home, '.local/share'),
  XDG_CONFIG_HOME: path.join(home, '.config'), TMPDIR: temporary, APPIMAGE_EXTRACT_AND_RUN: '1',
  BROWSER: `${quote(process.execPath)} ${quote(helper)} %s`};
let installed, executable, child, browser, page, endpoint, token, launches = 0;
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE
  ? pathToFileURL(path.resolve(process.env.PLAYWRIGHT_MODULE)).href : 'playwright');

function hash(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function check(name, pass, detail = '') {
  detail = mask(detail);
  result.checks.push({name, pass: Boolean(pass), detail});
  console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${detail ? '  ' + detail : ''}`);
}
function run(command, args) {
  const done = spawnSync(command, args, {encoding: 'utf8', env});
  assert.equal(done.status, 0, `${command} failed: ${done.stderr}`);
  return done.stdout;
}
async function api(route, body) {
  const response = await fetch(endpoint + route, {method: body === undefined ? 'GET' : 'POST',
    headers: {'Origin': endpoint, 'X-Estimator-Session': token, 'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)})});
  assert.ok(response.ok, `${route} returned ${response.status}: ${await response.clone().text()}`);
  return response.json();
}
async function status(route) {
  return (await fetch(endpoint + route, {headers: {'Origin': endpoint, 'X-Estimator-Session': token}})).status;
}
async function shot(name) {
  await page.waitForTimeout(3000);
  await page.screenshot({path: path.join(output, name), fullPage: true});
}
async function launch(project) {
  launches += 1;
  const logfile = path.join(output, `launch-${launches}.log`);
  let url, pending = '';
  child = spawn(executable, project ? ['--project', project] : [], {env, cwd: applications});
  const receive = chunk => {
    pending += chunk.toString();
    for (;;) {
      const split = pending.indexOf('\n');
      if (split < 0) break;
      const line = pending.slice(0, split); pending = pending.slice(split + 1);
      if (line.startsWith('BETA_BROWSER_URL=')) url = line.slice('BETA_BROWSER_URL='.length).trim();
      else fs.appendFileSync(logfile, mask(line) + '\n');
    }
  };
  child.stdout.on('data', receive); child.stderr.on('data', receive);
  const deadline = Date.now() + 120000;
  while (!url) {
    assert.equal(child.exitCode, null, 'Installed application exited before opening its browser');
    assert.ok(Date.now() < deadline, 'Installed application did not open its browser');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  endpoint = new URL(url).origin;
  token = new URLSearchParams(new URL(url).hash.slice(1)).get('session');
  assert.ok(token, 'Application browser URL has its local session');
  while ((await api('/api/v1/startup')).status !== 'ready') {
    assert.ok(Date.now() < deadline, 'Startup did not become ready');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  await page.goto(url);
  check(`Installed application launch ${launches}`, true);
}
async function stop() {
  if (!child || child.exitCode !== null) return;
  await api('/api/v1/session/close', {});
  if (child.exitCode !== null) {
    check(`Application exits cleanly ${launches}`, child.exitCode === 0, `exit ${child.exitCode}`);
    return;
  }
  let timer;
  const code = await Promise.race([once(child, 'exit').then(([value]) => value),
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Application did not close')), 60000); })])
    .finally(() => clearTimeout(timer));
  check(`Application exits cleanly ${launches}`, code === 0, `exit ${code}`);
}
async function ready() {
  await page.getByRole('region', {name: 'Plan viewer'}).waitFor({timeout: 60000});
  await page.waitForFunction(() => {
    const canvas = document.querySelector('.viewport-stage .sheet > canvas');
    return canvas?.style.visibility === 'visible' && canvas.width > 0;
  }, null, {timeout: 60000});
}

proof: try {
  if (process.platform === 'darwin') {
    const mount = path.join(output, 'mounted'); fs.mkdirSync(mount);
    run('hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mount, artifact]);
    installed = path.join(applications, 'TakeoffPal.app');
    try { run('ditto', [path.join(mount, 'TakeoffPal.app'), installed]); }
    finally { run('hdiutil', ['detach', mount]); }
    executable = path.join(installed, 'Contents/MacOS/TakeoffPal');
  } else {
    installed = path.join(applications, path.basename(artifact));
    fs.copyFileSync(artifact, installed); fs.chmodSync(installed, 0o755);
    assert.equal(hash(installed), result.sha256);
    executable = installed;
  }
  check('Installer copied into isolated Applications', fs.existsSync(executable));
  browser = await chromium.launch({channel: 'chrome', headless: process.env.PW_HEADLESS !== '0'});
  page = await browser.newPage({viewport: {width: 1440, height: 900}});
  page.setDefaultTimeout(30000);
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await launch();
  // The Beta Agreement comes first: until Agree nothing reaches Takeoff Pal, and the license is not even asked.
  const consent = await api('/api/v1/consent');
  check('The Beta Agreement comes first, the license waits for it', consent.accepted === false
    && await status('/api/v1/license') !== 200, `accepted ${consent.accepted}`);
  await api('/api/v1/consent', {choice: 'accepted', shown_text_sha256: '0'.repeat(64)});
  const gate = await api('/api/v1/license');
  check('Locked before a key (no_key)', gate.allowed === false && gate.reason === 'no_key', `allowed ${gate.allowed}, ${gate.reason}`);
  check('The gate holds: library answers 402', await status('/api/v1/library/items') === 402);
  await shot('gate-before-key.png');
  const license = await api('/api/v1/license', {key});
  if (expect === 'locked') check('The key is refused (bad_key or not_paid)', license.allowed === false
    && ['bad_key', 'not_paid'].includes(license.reason), `allowed ${license.allowed}, ${license.reason}`);
  else check('The key opens TakeoffPal', license.allowed === true, `allowed ${license.allowed}, ${license.reason}`);
  await stop();
  await launch(); await shot('gate-after-key.png');
  if (expect === 'locked') {
    check('Still locked at the next launch: library answers 402', await status('/api/v1/library/items') === 402);
    await stop(); break proof;  // The gate held; nothing else opens while locked.
  }
  const unlocked = await api('/api/v1/license');
  check('The saved key opens TakeoffPal at the next launch', unlocked.allowed === true, `${unlocked.reason}`);
  const library = await api('/api/v1/library/items'), source = (await api('/api/v1/session')).catalog_source;
  check('Built-in library connected on a fresh start', library.items.length === 1903
    && source?.licence_note === library.licence_note && source.licence_note.includes('© 2026 TakeoffPal'),
    `${library.items.length} items; ${source?.licence_note}`);
  const chosen = page.getByRole('button', {name: /Library chosen$/});
  await chosen.waitFor();
  check('First run shows Library chosen with no picker', await chosen.isDisabled());
  await page.screenshot({path: path.join(output, '00-library-chosen.png'), fullPage: true});
  await api('/api/v1/ui-prefs', {values: {'estimator.projectFolder': jobs, 'estimator.betaProof': result.sha256}});
  const plan = path.join(output, 'Beta install proof.pdf'); fs.writeFileSync(plan, blankPdf());
  await page.getByRole('button', {name: 'Choose plans', exact: true}).waitFor();
  await page.screenshot({path: path.join(output, '01-installed.png'), fullPage: true});
  const choose = page.waitForEvent('filechooser');
  await page.getByRole('button', {name: 'Choose plans', exact: true}).click();
  await (await choose).setFiles(plan); await ready();
  const session = await api('/api/v1/session'), project = session.project_path;
  assert.ok(project.startsWith(jobs + path.sep), 'Job is saved only in the proof home');
  assert.ok(fs.existsSync(project), 'Saved job exists');
  result.project = project;
  const before = await api('/api/v1/project');
  const documents = before.records.source_document.map(document => document.document_id);
  check('Create and save a job from the installed UI', documents.length === 1);
  await page.screenshot({path: path.join(output, '02-saved.png'), fullPage: true});
  const readers = await api('/api/v1/readers');
  check('Bundled native reader is available', readers.runtime?.available === true,
    JSON.stringify(readers.runtime));
  await stop();
  await launch(project); await ready();
  const reopened = await api('/api/v1/project');
  check('Saved job and plan reopen after process restart',
    JSON.stringify(reopened.records.source_document.map(document => document.document_id)) === JSON.stringify(documents)
    && reopened.generation === before.generation);
  const prefs = await api('/api/v1/ui-prefs');
  check('Native preferences survive process restart', prefs.values['estimator.betaProof'] === result.sha256);
  await page.screenshot({path: path.join(output, '03-reopened.png'), fullPage: true});
  check('No browser errors', errors.length === 0, JSON.stringify(errors));
  await stop(); await browser.close(); browser = null;
  const saved = hash(project);
  fs.rmSync(installed, {recursive: true});
  check('Uninstall removes this installation', !fs.existsSync(installed));
  check('Uninstall preserves the saved job', fs.existsSync(project) && hash(project) === saved);
  check('Uninstall preserves native preferences', fs.existsSync(path.join(home,
    process.platform === 'darwin' ? 'Library/Application Support' : '.local/share', 'Estimator/settings/ui-prefs.json')));
} catch (error) {
  check('Install proof completed', false, String(error.stack));
} finally {
  if (child && child.exitCode === null) child.kill('SIGTERM');
  if (browser) await browser.close();
  result.status = result.checks.every(item => item.pass) ? 'PASS' : 'FAIL';
  fs.writeFileSync(path.join(output, 'receipt.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(result.status);
  process.exitCode = result.status === 'PASS' ? 0 : 1;
}
