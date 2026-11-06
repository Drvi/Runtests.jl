'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const model = require('../src/model');

const key = name => model.keyOf('P', name);
const object = name => ({ package: 'P', name });

test('an item is known by its package and its name', () => {
    assert.notEqual(model.keyOf('A', 'same'), model.keyOf('B', 'same'));
    assert.deepEqual(model.keyObject(model.keyOf('A', 'with :: in it')), { package: 'A', name: 'with :: in it' });
    assert.equal(model.itemKey({ package: 'A', name: 'x' }), model.keyOf('A', 'x'));
});

test('what a run did not select of what was queued is told apart from what it does not know', () => {
    const started = { items: [object('fast')], unknown: [object('gone')] };
    assert.deepEqual(model.unselected([key('fast'), key('slow'), key('gone')], started), [key('slow')]);
    assert.deepEqual(model.unselected([key('fast')], { items: [object('fast')] }), []);
});

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

test('a name declared twice is in the tree once, where the listing has it first', () => {
    // Keys are the tree's ids, and VS Code throws on a repeated one; the listing's
    // errors say where the other declaration is.
    const items = [
        { name: 'same', file: '/p/test/a_test.jl', line: 1 },
        { name: 'same', file: '/p/test/a_test.jl', line: 4 },
        { name: 'other', file: '/p/test/b_test.jl', line: 1 },
        { name: 'other', file: '/p/test/a_test.jl', line: 9 },
    ];
    const files = model.groupByFile(items, '/p/test');
    assert.deepEqual(files.map(f => [f.relpath, f.items.map(it => `${it.name}:${it.line}`)]),
        [['a_test.jl', ['same:1']], ['b_test.jl', ['other:1']]]);
});

test('a server of several packages groups their items by package, then by file', () => {
    const items = [
        { package: 'B', name: 'same', file: '/w/lib/B/test/b_test.jl', line: 1 },
        { package: 'A', name: 'same', file: '/w/lib/A/test/a_test.jl', line: 1 },
        { package: 'A', name: 'a2', file: '/w/lib/A/test/a_test.jl', line: 5 },
    ];
    const packages = [
        { name: 'A', root: '/w/lib/A', testdir: '/w/lib/A/test' },
        { name: 'B', root: '/w/lib/B', testdir: '/w/lib/B/test' },
        { name: 'C', root: '/w/lib/C', testdir: '/w/lib/C/test' },
    ];
    const groups = model.groupByPackage(items, packages);
    // Two items of one name, one in each package; a package without items is left out.
    assert.deepEqual(groups.map(g => [g.package, g.files.map(f => [f.relpath, f.items.map(it => it.name)])]),
        [['A', [['a_test.jl', ['same', 'a2']]]], ['B', [['b_test.jl', ['same']]]]]);
});

test('a folder is a workspace of several packages when it lists members besides its tests', () => {
    assert.equal(model.isMonorepo('[workspace]\nprojects = ["lib/A", "lib/A/test", "test"]\n'), true);
    assert.equal(model.isMonorepo('name = "P"\n\n[workspace]\nprojects = ["test"]\n'), false);
    assert.equal(model.isMonorepo('name = "P"\n[deps]\n'), false);
    // TOML's literal strings, in single quotes, name members as well.
    assert.equal(model.isMonorepo("[workspace]\nprojects = ['lib/A', 'lib/A/test']\n"), true);
    assert.equal(model.isMonorepo("name = 'P'\n\n[workspace]\nprojects = ['test']\n"), false);
    assert.deepEqual(model.workspaceMembers("[workspace]\nprojects = ['lib/A', \"./lib/B\", 'lib\\C']\n"), ['lib/A', 'lib/B', 'lib/C']);
});

// Project files as Julia's TOML reads them: the members of their workspace, and
// whether `[deps]` holds Runtests. The answers are `TOML.parse`'s for the same text.
test('a project file is read as TOML is, comments, layout and quotes included', () => {
    const uuid = '632efd68-cd41-4e05-bd25-b86dc2150078';
    const cases = [
        ['[workspace]\n# lib/[old] moved here\nprojects = ["lib/A", "test"]\n', ['lib/A', 'test'], false],
        ['[workspace]\n# projects = ["lib/Z"]\nprojects = ["test"]\n', ['test'], false],
        ["[workspace]\nprojects = [\n    \"lib/A\",  # the first [one]\n    'lib/B',\n]\n", ['lib/A', 'lib/B'], false],
        [`name = "P"\n  [deps]\n  Runtests = "${uuid}"\n  [extras]\n  Foo = "11111111-1111-1111-1111-111111111111"\n`, [], true],
        [`[deps]\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n  [extras]\n  Runtests = "${uuid}"\n`, [], false],
        [`name = "P"\ndeps.Runtests = "${uuid}"\n\n[sources]\nRuntests = {path = "/x", rev = "main"}\n\n[workspace]\nprojects = ["lib/A"]\n`,
         ['lib/A'], true],
        [`[workspace]\r\nprojects = ["test", "lib/A"]\r\n[deps]\r\nRuntests = "${uuid}"\r\n`, ['test', 'lib/A'], true],
        ['description = """\nA package [with brackets]\nprojects = ["fake"]\n"""\n[workspace]\nprojects = ["lib/B"]\n', ['lib/B'], false],
    ];
    for (const [text, members, runtests] of cases) {
        assert.deepEqual(model.workspaceMembers(text), members, text);
        assert.equal(model.declaresRuntests(text), runtests, text);
    }
    // What is not TOML has neither.
    assert.deepEqual(model.workspaceMembers('[workspace\nprojects = ["lib/A"]\n'), []);
    assert.throws(() => model.parseToml('a = "unterminated\n'), /not TOML/);
});

// Files under `root`, by their paths relative to it, for what the extension reads.
const root = path.join(path.sep, 'ws');
const at = rel => path.join(root, ...rel.split('/'));
const files = entries => {
    const m = new Map(entries.map(([rel, text]) => [at(rel), text]));
    return { m, read: file => m.get(file) ?? null };
};

test('a folder changes mode as its project and the setting change', () => {
    const fs = files([['Project.toml', 'name = "P"\n[workspace]\nprojects = ["test"]\n']]);
    assert.equal(model.isCombined('auto', root, fs.read), false);
    fs.m.set(at('Project.toml'), 'name = "P"\n[workspace]\nprojects = ["test", "lib/A"]\n');
    assert.equal(model.isCombined('auto', root, fs.read), true);
    assert.equal(model.isCombined('off', root, fs.read), false);
    fs.m.set(at('Project.toml'), 'name = "P"\n');
    assert.equal(model.isCombined('auto', root, fs.read), false);
    assert.equal(model.isCombined('on', root, fs.read), true);
    // Julia reads JuliaProject.toml before Project.toml.
    fs.m.set(at('JuliaProject.toml'), "[workspace]\nprojects = ['lib/A']\n");
    assert.equal(model.isCombined('auto', root, fs.read), true);
    assert.equal(model.isCombined('auto', at('none'), fs.read), false);
});

const RUNTESTS = 'Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"';

test('a project can load Runtests when its [deps] names it', () => {
    assert.equal(model.declaresRuntests(`[deps]\n${RUNTESTS}\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n`), true);
    assert.equal(model.declaresRuntests(`name = "A"\r\n\r\n[deps]\r\n${RUNTESTS}\r\n`), true);
    assert.equal(model.declaresRuntests(`[deps]\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n\n[extras]\n${RUNTESTS}\n`), false);
    assert.equal(model.declaresRuntests(`[deps]\nRuntests = "00000000-0000-0000-0000-000000000000"\n`), false);
    assert.equal(model.declaresRuntests('name = "A"\n'), false);
});

test('the server runs in an environment that can load Runtests', () => {
    // A workspace without a root package, where only the members' test projects have Runtests.
    const ws = files([
        ['Project.toml', '[workspace]\nprojects = ["lib/A", "lib/B"]\n'],
        ['lib/A/Project.toml', 'name = "A"\n[workspace]\nprojects = ["test"]\n'],
        ['lib/A/test/Project.toml', '[deps]\nTest = "8dfed614-e22c-5e08-85e1-65c5234f0b40"\n'],
        ['lib/B/test/Project.toml', `[deps]\n${RUNTESTS}\n`],
    ]);
    assert.equal(model.serverEnvironment({ root, combined: true, read: ws.read }), at('lib/B/test'));
    // The root's own test project comes first.
    ws.m.set(at('test/Project.toml'), `[deps]\n${RUNTESTS}\n`);
    assert.equal(model.serverEnvironment({ root, combined: true, read: ws.read }), at('test'));
    // When none has Runtests: the root, where the server says what it lacks.
    const bare = files([['Project.toml', "[workspace]\nprojects = ['lib/A']\n"]]);
    assert.equal(model.serverEnvironment({ root, combined: true, read: bare.read }), root);
    // A folder of one package: its test project when there is one.
    const one = files([['Project.toml', 'name = "P"\n'], ['test/Project.toml', '[deps]\n']]);
    assert.equal(model.serverEnvironment({ root, combined: false, read: one.read }), at('test'));
    assert.equal(model.serverEnvironment({ root, combined: false, read: bare.read }), root);
    // The setting decides when it is given.
    assert.equal(model.serverEnvironment({ root, combined: true, setting: 'env', read: ws.read }), at('env'));
});

test('a change to the project restarts a server whose mode or environment it changes, and lists again otherwise', () => {
    const serving = { combined: true, environment: '/ws/test' };
    assert.equal(model.folderChange(serving, { combined: true, environment: '/ws/test' }), 'refresh');
    assert.equal(model.folderChange(serving, { combined: false, environment: '/ws/test' }), 'restart');
    assert.equal(model.folderChange(serving, { combined: true, environment: '/ws/lib/A/test' }), 'restart');
});

test('a workspace of several packages does not use runtests.config, and says so', () => {
    assert.match(model.configProblem(true, 'other.toml'), /not used/);
    assert.equal(model.configProblem(false, 'other.toml'), null);
    assert.equal(model.configProblem(true, ''), null);
    assert.equal(model.configProblem(true, undefined), null);
});

test('a selection is the items under what is included, less what is excluded', () => {
    const under = new Map([
        ['file:a', ['a1', 'a2']], ['file:b', ['b1']], ['item:a1', ['a1']], ['item:a2', ['a2']], ['item:b1', ['b1']],
    ]);
    const all = ['a1', 'a2', 'b1'];
    // Nothing chosen and nothing left out: the whole suite, sent as no items at all.
    assert.equal(model.selectedKeys(undefined, [], under, all), null);
    assert.deepEqual(model.selectedKeys(['file:a'], [], under, all), ['a1', 'a2']);
    assert.deepEqual(model.selectedKeys(['file:a', 'item:b1'], ['item:a2'], under, all), ['a1', 'b1']);
    // Everything but what is left out.
    assert.deepEqual(model.selectedKeys(undefined, ['file:a'], under, all), ['b1']);
    // An item under two chosen nodes is run once.
    assert.deepEqual(model.selectedKeys(['file:a', 'item:a1'], [], under, all), ['a1', 'a2']);
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
