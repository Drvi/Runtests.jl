// The Test Explorer side: one Runtests server per workspace folder with a test suite,
// its items as a tree of files, runs as test runs. What is decided without VS Code
// is in `model.js`, and the protocol is in `server.js`.
'use strict';

const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const { RuntestsServer } = require('./server');
const model = require('./model');

/** @param {vscode.ExtensionContext} context */
function activate(context) {
    const log = vscode.window.createOutputChannel('Runtests');
    const ctrl = vscode.tests.createTestController('runtests', 'Runtests');
    const diagnostics = vscode.languages.createDiagnosticCollection('runtests');
    context.subscriptions.push(log, ctrl, diagnostics);

    /** @type {Map<string, Suite>} workspace folder uri -> its suite */
    const suites = new Map();
    const multiRoot = () => suites.size > 1;

    let listed = false;

    // With one suite its files are at the top of the tree, with several each hangs
    // under its folder: crossing between the two rebuilds the tree.
    function regroup(wasMulti) {
        if (wasMulti === multiRoot()) return;
        ctrl.items.replace([]);
        if (listed) for (const s of suites.values()) s.refresh();
    }

    // The toolbar's Runtests buttons show only in a workspace with a suite.
    const announce = () => vscode.commands.executeCommand('setContext', 'runtests.active', suites.size > 0);

    async function addFolder(folder) {
        const found = await vscode.workspace.findFiles(new vscode.RelativePattern(folder, 'test/**/{*_test.jl,*_tests.jl}'), null, 1);
        if (found.length === 0 || suites.has(folder.uri.toString())) return;
        const wasMulti = multiRoot();
        const suite = new Suite(folder, ctrl, diagnostics, log, multiRoot);
        suites.set(folder.uri.toString(), suite);
        announce();
        context.subscriptions.push(suite);
        // VS Code asks for the items when the Test Explorer is shown; a folder
        // added after that is listed at once.
        if (listed) suite.refresh();
        regroup(wasMulti);
    }

    ctrl.resolveHandler = async item => {
        if (item) return;
        listed = true;
        await Promise.all([...suites.values()].map(s => s.refresh()));
    };
    ctrl.refreshHandler = async () => {
        await Promise.all([...suites.values()].map(s => s.refresh()));
    };

    const runProfile = ctrl.createRunProfile('Run', vscode.TestRunProfileKind.Run, async (request, token) => {
        const run = ctrl.createTestRun(request);
        try {
            for (const suite of suites.values()) {
                if (token.isCancellationRequested) break;
                await suite.run(request, run, token);
            }
        } finally {
            run.end();
        }
    }, true);

    context.subscriptions.push(
        vscode.commands.registerCommand('runtests.restart', async () => {
            await Promise.all([...suites.values()].map(s => s.restart()));
        }),
        vscode.commands.registerCommand('runtests.showLog', () => log.show()),
        // What is failing — each item as the last run that ran it left it, here, in a
        // terminal or on CI — run like any other selection, so it shows in the Test
        // Results like one.
        vscode.commands.registerCommand('runtests.runFailed', async () => {
            const items = [];
            for (const s of suites.values()) items.push(...await s.failedItems());
            if (items.length === 0) {
                vscode.window.showInformationMessage('Runtests: no test item is failing');
                return;
            }
            const source = new vscode.CancellationTokenSource();
            try {
                await runProfile.runHandler(new vscode.TestRunRequest(items, undefined, runProfile), source.token);
            } finally {
                source.dispose();
            }
        }),
        vscode.workspace.onDidChangeWorkspaceFolders(async e => {
            const wasMulti = multiRoot();
            for (const f of e.removed) {
                const s = suites.get(f.uri.toString());
                if (s) {
                    s.forget();
                    s.dispose();
                    suites.delete(f.uri.toString());
                }
            }
            regroup(wasMulti);
            announce();
            for (const f of e.added) await addFolder(f);
        }),
    );

    // What another extension, or a test in an extension host, can reach.
    const api = { controller: ctrl, runProfile, refresh: () => ctrl.refreshHandler() };
    return Promise.all((vscode.workspace.workspaceFolders ?? []).map(addFolder)).then(() => api);
}

/** One workspace folder's suite: its server, its items in the tree, its runs. */
class Suite {
    constructor(folder, ctrl, diagnostics, log, multiRoot) {
        this.folder = folder;
        this.ctrl = ctrl;
        this.diagnostics = diagnostics;
        this.log = log;
        this.multiRoot = multiRoot;
        this.server = null;
        this.byName = new Map();    // item name -> TestItem
        this.under = new Map();     // node id -> names of the items at or below it
        this.queue = Promise.resolve();
        this.root = folder.uri.fsPath;
        this.disposables = [];
        // Test files and settings changing change the listing.
        const watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, 'test/**/*.{jl,toml}'));
        let timer = null;
        const later = () => {
            clearTimeout(timer);
            timer = setTimeout(() => this.refresh(), 300);
        };
        watcher.onDidChange(later);
        watcher.onDidCreate(later);
        watcher.onDidDelete(later);
        this.disposables.push(watcher, { dispose: () => clearTimeout(timer) });
    }

    id(kind, rest) { return `${this.folder.uri.toString()}::${kind}::${rest}`; }

    // Where the tree of this folder hangs: at the top, or under the folder's own
    // node when the workspace has several suites.
    container() {
        if (!this.multiRoot()) return this.ctrl.items;
        const id = this.id('folder', '');
        let node = this.ctrl.items.get(id);
        if (!node) {
            node = this.ctrl.createTestItem(id, this.folder.name, this.folder.uri);
            this.ctrl.items.add(node);
        }
        return node.children;
    }

    ensureServer() {
        if (this.server?.running) return this.server;
        const config = vscode.workspace.getConfiguration('runtests', this.folder);
        const julia = config.get('julia.executable') || vscode.workspace.getConfiguration('julia').get('executablePath') || 'julia';
        const environment = config.get('environment')
            ? path.resolve(this.root, config.get('environment'))
            : fs.existsSync(path.join(this.root, 'test', 'Project.toml')) ? path.join(this.root, 'test') : this.root;
        this.server = new RuntestsServer({
            julia, juliaArgs: config.get('julia.args') ?? [], environment, root: this.root,
            // What Runtests writes for people: into the output of the run in progress,
            // shown in a terminal, and into the log.
            onLog: line => {
                this.log.appendLine(model.plain(line));
                this.activeRun?.appendOutput(line + '\r\n');
            },
        });
        this.server.on('exit', (code, signal) => this.log.appendLine(`[${this.folder.name}] server exited (${signal ?? `code ${code}`})`));
        return this.server;
    }

    async refresh() {
        let listing;
        try {
            listing = await this.ensureServer().list();
        } catch (err) {
            this.log.appendLine(`[${this.folder.name}] could not list the test items: ${err.message}`);
            vscode.window.showErrorMessage(`Runtests: could not list the test items of ${this.folder.name}: ${err.message}`, 'Show Log')
                .then(choice => choice && this.log.show());
            return;
        }
        this.show(listing);
    }

    show(listing) {
        const container = this.container();
        const files = model.groupByFile(listing.items, listing.testdir);
        const all = listing.items.map(it => it.name);
        this.byName.clear();
        this.under.clear();
        const nodes = [];
        for (const f of files) {
            const uri = vscode.Uri.file(f.file);
            const fileNode = this.ctrl.createTestItem(this.id('file', f.relpath), f.relpath, uri);
            fileNode.children.replace(f.items.map(it => {
                const node = this.ctrl.createTestItem(this.id('item', it.name), it.name, uri);
                node.range = new vscode.Range(it.line - 1, 0, it.end_line - 1, 0);
                node.tags = it.tags.map(t => new vscode.TestTag(t));
                node.description = describe(it);
                this.byName.set(it.name, node);
                this.under.set(node.id, [it.name]);
                return node;
            }));
            this.under.set(fileNode.id, f.items.map(it => it.name));
            nodes.push(fileNode);
        }
        container.replace(nodes);
        if (this.multiRoot()) this.under.set(this.id('folder', ''), all);
        this.all = all;
        this.failed = listing.failed ?? [];
        // What would stop a run, where it is.
        const byFile = new Map();
        for (const e of listing.errors) {
            const line = Math.max(e.line - 1, 0);
            const d = new vscode.Diagnostic(new vscode.Range(line, 0, line, 1000), e.message, vscode.DiagnosticSeverity.Error);
            d.source = 'Runtests';
            if (!byFile.has(e.file)) byFile.set(e.file, []);
            byFile.get(e.file).push(d);
        }
        for (const [file] of this.reported ?? []) if (!byFile.has(file)) this.diagnostics.delete(vscode.Uri.file(file));
        for (const [file, ds] of byFile) this.diagnostics.set(vscode.Uri.file(file), ds);
        this.reported = byFile;
    }

    // The items that are failing, as the server lists them now.
    async failedItems() {
        await this.refresh();
        return (this.failed ?? []).map(n => this.byName.get(n)).filter(Boolean);
    }

    // The part of `request` that is this folder's, as item names; `undefined` when
    // none of it is.
    namesFor(request) {
        const mine = node => this.under.has(node.id);
        const include = request.include?.filter(mine).map(n => n.id);
        const exclude = (request.exclude ?? []).filter(mine).map(n => n.id);
        if (request.include && include.length === 0) return undefined;
        return model.selectedNames(include, exclude, this.under, this.all ?? []);
    }

    async run(request, run, token) {
        if (!this.all) await this.refresh();
        const names = this.namesFor(request);
        if (names === undefined || (names !== null && names.length === 0)) return;
        const targets = (names ?? this.all ?? []).map(n => this.byName.get(n)).filter(Boolean);
        for (const t of targets) run.enqueued(t);
        // One run at a time per server: the next waits for this one.
        const previous = this.queue;
        let done;
        this.queue = new Promise(resolve => { done = resolve; });
        try {
            await previous;
            if (token.isCancellationRequested) {
                for (const t of targets) run.skipped(t);
                return;
            }
            await this.runOnServer(names, run, token, targets);
        } finally {
            done();
        }
    }

    async runOnServer(names, run, token, targets) {
        const server = this.ensureServer();
        const options = vscode.workspace.getConfiguration('runtests', this.folder).get('run.options') ?? {};
        // Stopped from wherever it was started, and from the run's own Stop.
        const cancels = [token.onCancellationRequested(() => server.cancel()),
            run.token.onCancellationRequested(() => server.cancel())];
        this.activeRun = run;
        let unknownSeen = false;
        const settled = new Set();
        try {
            const end = await server.run(names, options, ev => {
                const item = ev.name !== undefined ? this.byName.get(ev.name) : undefined;
                if (ev.event === 'run_started') {
                    for (const n of ev.unknown) {
                        const t = this.byName.get(n);
                        if (t) run.errored(t, new vscode.TestMessage('not in the suite any more'));
                        unknownSeen = true;
                    }
                } else if (ev.event === 'item_started') {
                    if (item) run.started(item);
                    else unknownSeen = true;
                } else if (ev.event === 'item_finished' && item) {
                    settled.add(ev.name);
                    this.finish(run, item, ev);
                }
            });
            if (end.event === 'error' || end.event === 'exit' || end.state === 'error') {
                // What had an outcome keeps it; the rest could not run.
                const text = end.event === 'error' ? end.message : end.event === 'exit' ? end.error.message :
                    'the run stopped with an error; see the Runtests log';
                for (const t of targets) if (!settled.has(t.label)) run.errored(t, new vscode.TestMessage(text));
                run.appendOutput(model.crlf(`Runtests: ${text}\n`));
            } else {
                for (const n of end.not_run ?? []) {
                    const t = this.byName.get(n);
                    if (t) run.skipped(t);
                }
            }
        } finally {
            this.activeRun = null;
            for (const c of cancels) c.dispose();
        }
        // A name the tree does not know means the listing is behind the files.
        if (unknownSeen) this.refresh();
    }

    finish(run, item, ev) {
        const o = model.outcome(ev);
        const messages = o.messages.map(m => {
            const msg = new vscode.TestMessage(m.text);
            if (m.file) msg.location = new vscode.Location(vscode.Uri.file(m.file), new vscode.Position(Math.max(m.line - 1, 0), 0));
            return msg;
        });
        if (o.kind === 'passed') run.passed(item, o.durationMs);
        else if (o.kind === 'skipped') run.skipped(item);
        else if (o.kind === 'failed') run.failed(item, messages, o.durationMs);
        else run.errored(item, messages, o.durationMs);
    }

    // Take this folder's items out of the tree and its problems out of the editor.
    forget() {
        const prefix = `${this.folder.uri.toString()}::`;
        const mine = [];
        this.ctrl.items.forEach(node => { if (node.id.startsWith(prefix)) mine.push(node.id); });
        for (const id of mine) this.ctrl.items.delete(id);
        for (const [file] of this.reported ?? []) this.diagnostics.delete(vscode.Uri.file(file));
    }

    async restart() {
        if (this.server) await this.server.stop();
        this.server = null;
        await this.refresh();
    }

    dispose() {
        this.server?.stop();
        for (const d of this.disposables) d.dispose();
    }
}

// What the tree says beside an item's name: what sets it apart from the rest.
function describe(it) {
    const parts = [];
    if (it.tags.length) parts.push(it.tags.join(', '));
    if (it.profile) parts.push(`profile ${it.profile}`);
    else if (it.sandbox) parts.push('sandbox');
    if (it.chain) parts.push(`chain ${it.chain}`);
    if (it.skip !== false) parts.push(it.skip === true ? 'skipped' : `skip if ${it.skip}`);
    return parts.join(' · ');
}

function deactivate() {}

module.exports = { activate, deactivate };
