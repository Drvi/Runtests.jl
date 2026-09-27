// A smoke test inside VS Code: the extension lists a package's items into the Test
// Explorer and runs them. Started by `test/extension/run.js`, which opens a VS Code
// of its own on a package made for the test.
'use strict';

const vscode = require('vscode');
const assert = require('node:assert/strict');

async function run() {
    const ext = vscode.extensions.getExtension('yatf.yatf');
    const api = await ext.activate();
    await api.refresh();
    const ctrl = api.controller;

    const files = [];
    ctrl.items.forEach(f => files.push(f));
    assert.deepEqual(files.map(f => f.label), ['a_test.jl']);
    const items = [];
    files[0].children.forEach(i => items.push(i));
    assert.deepEqual(items.map(i => i.label), ['passes', 'fails', 'tagged']);
    const tagged = items[2];
    assert.deepEqual(tagged.tags.map(t => t.id), ['fast']);
    assert.equal(tagged.range.start.line, 7);

    // What the run says about each item, and what it writes, caught on its way to VS Code.
    const said = new Map();
    let output = '';
    const createTestRun = ctrl.createTestRun.bind(ctrl);
    ctrl.createTestRun = (...args) => {
        const r = createTestRun(...args);
        const appendOutput = r.appendOutput.bind(r);
        r.appendOutput = (text, ...rest) => {
            output += text;
            return appendOutput(text, ...rest);
        };
        for (const kind of ['passed', 'failed', 'errored', 'skipped']) {
            const original = r[kind].bind(r);
            r[kind] = (item, ...rest) => {
                said.set(item.label, { kind, rest });
                return original(item, ...rest);
            };
        }
        return r;
    };
    const source = new vscode.CancellationTokenSource();
    await api.runProfile.runHandler(new vscode.TestRunRequest([items[0], items[1]]), source.token);
    assert.equal(said.get('passes').kind, 'passed');
    const fails = said.get('fails');
    assert.equal(fails.kind, 'failed');
    const [messages] = fails.rest;
    assert.equal(messages[0].location.range.start.line, 5);
    assert.match(messages[0].message, /x == 2/);
    assert.equal(said.has('tagged'), false);

    // The run's output is what YATF wrote, in colour, a line per terminal line.
    const plain = output.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');
    assert.match(plain, /DONE .*"fails".*FAIL/);
    assert.match(plain, /ran 2 test items/);
    assert.match(output, /\x1b\[/);
    assert.ok(!/[^\r]\n/.test(output), 'every line ends in CRLF');

    // Run Failed Tests runs what is failing, and nothing else: each item as the last
    // run that ran it left it, so a run of another item in between changes nothing.
    await api.runProfile.runHandler(new vscode.TestRunRequest([items[0]]), source.token);
    said.clear();
    await vscode.commands.executeCommand('yatf.runFailed');
    assert.deepEqual([...said.keys()], ['fails']);
}

module.exports = { run };
