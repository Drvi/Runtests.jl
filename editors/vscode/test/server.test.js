// Against a real server: Runtests from this checkout, serving a package made for the
// test. `julia` from the PATH, or `RUNTESTS_TEST_JULIA`.
'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { RuntestsServer, PROTOCOL } = require('../src/server');

const REPO = path.resolve(__dirname, '..', '..', '..');
const julia = process.env.RUNTESTS_TEST_JULIA ?? 'julia';
const sep = process.platform === 'win32' ? ';' : ':';

function makePackage() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'runtests-vscode-'));
    fs.writeFileSync(path.join(dir, 'Project.toml'),
        'name = "Served"\nuuid = "0b0b0b0b-0000-4000-8000-00000000cafe"\nversion = "0.1.0"\n');
    fs.mkdirSync(path.join(dir, 'src'));
    fs.writeFileSync(path.join(dir, 'src', 'Served.jl'), 'module Served\nend\n');
    fs.mkdirSync(path.join(dir, 'test'));
    const item = (name, body) => `@testitem "${name}" begin\n    ${body}\nend\n`;
    fs.writeFileSync(path.join(dir, 'test', 'a_test.jl'),
        item('passes', '@test true') + item('fails', 'x = 1\n    @test x == 2') +
        item('slow 1', 'sleep(600)') + item('slow 2', 'sleep(600)'));
    return dir;
}

let dir, server;
const log = [];

before(async () => {
    dir = makePackage();
    server = new RuntestsServer({
        julia, juliaArgs: [], environment: REPO, root: dir, onLog: line => log.push(line),
        env: {
            ...process.env,
            // Workers find RuntestsWorkers through the load path, as the Julia tests arrange.
            JULIA_LOAD_PATH: [REPO, path.join(REPO, 'test'), ''].join(sep),
            RUNTESTS_RUNSTATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'runtests-runs-')),
        },
    });
    const hello = await server.start();
    assert.equal(hello.protocol, PROTOCOL);
    assert.equal(hello.root, dir);   // as given: the paths VS Code has
}, { timeout: 180_000 });

after(async () => {
    await server?.stop();
    fs.rmSync(dir, { recursive: true, force: true });
});

test('the listing holds every item, where it is', async () => {
    const listing = await server.list();
    assert.deepEqual(listing.items.map(it => it.name), ['passes', 'fails', 'slow 1', 'slow 2']);
    assert.deepEqual(listing.errors, []);
    const fails = listing.items[1];
    assert.equal(path.basename(fails.file), 'a_test.jl');
    assert.equal(fails.line, 4);
    assert.equal(fails.end_line, 7);
});

test('a run reports each item as it goes, a failure where it is', { timeout: 240_000 }, async () => {
    const events = [];
    const end = await server.run(['passes', 'fails'], { workers: 1 }, ev => events.push(ev));
    assert.equal(end.event, 'run_finished');
    assert.equal(end.state, 'failed');
    const kinds = events.map(e => e.event);
    assert.equal(kinds[0], 'run_started');
    assert.equal(kinds.filter(k => k === 'item_started').length, 2);
    const finished = Object.fromEntries(events.filter(e => e.event === 'item_finished').map(e => [e.name, e]));
    assert.equal(finished.passes.state, 'passed');
    assert.equal(finished.fails.state, 'failed');
    const failure = finished.fails.failures[0];
    assert.equal(failure.line, 6);
    assert.match(failure.message, /x == 2/);
    // What an editor's "run failed" runs next.
    assert.deepEqual((await server.list()).failed, ['fails']);
});

test('a run that cannot start ends with its error', { timeout: 120_000 }, async () => {
    const end = await server.run(['no such item'], {}, () => {});
    assert.equal(end.event, 'error');
    assert.match(end.message, /no test items matched/);
});

test('a cancel stops a run at once', { timeout: 240_000 }, async () => {
    let cancelledAt = null;
    const end = await server.run(['slow 1', 'slow 2'], { workers: 2 }, ev => {
        if (ev.event === 'item_started' && cancelledAt === null) {
            cancelledAt = Date.now();
            server.cancel();
        }
    });
    assert.equal(end.event, 'run_finished');
    assert.equal(end.state, 'cancelled');
    assert.ok(Date.now() - cancelledAt < 30_000, 'the run stopped well before its items would have');
});

test('a julia that cannot be started is said, and tried again next time', async () => {
    const missing = new RuntestsServer({ julia: path.join(os.tmpdir(), 'no-such-julia'), environment: REPO, root: dir });
    await assert.rejects(missing.start());
    assert.equal(missing.running, false);
    await assert.rejects(missing.start());
});
