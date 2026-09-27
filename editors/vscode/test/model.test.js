'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const model = require('../src/model');

test('items group into files, in order, with paths relative to the test directory', () => {
    const items = [
        { name: 'b2', file: '/p/test/sub/b_test.jl', line: 9 },
        { name: 'a1', file: '/p/test/a_test.jl', line: 1 },
        { name: 'b1', file: '/p/test/sub/b_test.jl', line: 1 },
    ];
    const files = model.groupByFile(items, '/p/test');
    assert.deepEqual(files.map(f => f.relpath), ['a_test.jl', 'sub/b_test.jl']);
    assert.deepEqual(files[1].items.map(it => it.name), ['b1', 'b2']);
});

test('a selection is the items under what is included, less what is excluded', () => {
    const under = new Map([
        ['file:a', ['a1', 'a2']], ['file:b', ['b1']], ['item:a1', ['a1']], ['item:a2', ['a2']], ['item:b1', ['b1']],
    ]);
    const all = ['a1', 'a2', 'b1'];
    // Nothing chosen and nothing left out: the whole suite, sent as no names at all.
    assert.equal(model.selectedNames(undefined, [], under, all), null);
    assert.deepEqual(model.selectedNames(['file:a'], [], under, all), ['a1', 'a2']);
    assert.deepEqual(model.selectedNames(['file:a', 'item:b1'], ['item:a2'], under, all), ['a1', 'b1']);
    // Everything but what is left out.
    assert.deepEqual(model.selectedNames(undefined, ['file:a'], under, all), ['b1']);
    // An item under two chosen nodes is run once.
    assert.deepEqual(model.selectedNames(['file:a', 'item:a1'], [], under, all), ['a1', 'a2']);
});

test('an outcome says what to show, and where', () => {
    const passed = model.outcome({ state: 'passed', elapsed: 0.25, note: '', failures: [] });
    assert.deepEqual(passed, { kind: 'passed', durationMs: 250, messages: [] });
    const failed = model.outcome({
        state: 'failed', elapsed: 0.1, note: '',
        failures: [{ kind: 'fail', message: 'Test Failed at a_test.jl:3', file: '/p/test/a_test.jl', line: 3 }],
    });
    assert.equal(failed.kind, 'failed');
    assert.deepEqual(failed.messages, [{ text: 'Test Failed at a_test.jl:3', file: '/p/test/a_test.jl', line: 3 }]);
    // An outcome the run decided has no failure of its own: its note stands for it,
    // or its state in words.
    const timedout = model.outcome({ state: 'timedout', elapsed: 2, note: 'timed out after 2s', failures: [] });
    assert.equal(timedout.kind, 'errored');
    assert.deepEqual(timedout.messages, [{ text: 'timed out after 2s', file: null, line: 0 }]);
    assert.equal(model.outcome({ state: 'broken_chain', elapsed: 0, note: '', failures: [] }).messages[0].text,
        'did not run: an earlier item of its chain lost its worker');
    assert.equal(model.outcome({ state: 'cancelled', elapsed: 0, note: '', failures: [] }).kind, 'skipped');
    assert.equal(model.outcome({ state: 'skipped', elapsed: 0, note: '', failures: [] }).kind, 'skipped');
});

test('output gets the line ends a terminal wants', () => {
    assert.equal(model.crlf('a\nb\r\nc'), 'a\r\nb\r\nc');
});

test('the log gets the text without its colours', () => {
    assert.equal(model.plain('\x1b[1m\x1b[32mPASS\x1b[39m\x1b[22m in 0.1s'), 'PASS in 0.1s');
    assert.equal(model.plain('no colour'), 'no colour');
});
