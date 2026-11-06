// The Test Explorer side: one Runtests server per workspace folder with a test suite,
// its items as a tree of files, under a node for each package when the folder is a
// workspace of several, and runs as test runs. What is decided without VS Code is
// in `model.js`, and the protocol is in `server.js`.
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
        // The test directory of the folder's package, or of a package under it.
        const found = await vscode.workspace.findFiles(new vscode.RelativePattern(folder, '**/test/**/{*_test.jl,*_tests.jl}'), null, 1);
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
        this.byKey = new Map();     // item key (`model.keyOf`) -> TestItem
        this.keyById = new Map();   // TestItem id -> item key
        this.under = new Map();     // node id -> keys of the items at or below it
        this.queue = Promise.resolve();
        this.root = folder.uri.fsPath;
        this.combined = this.mode();
        this.disposables = [];
        // Test files and settings changing change the listing.
        const watcher = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, '**/test/**/*.{jl,toml}'));
        let timer = null;
        const later = () => {
            clearTimeout(timer);
            timer = setTimeout(() => this.refresh(), 300);
        };
        watcher.onDidChange(later);
        watcher.onDidCreate(later);
        watcher.onDidDelete(later);
        // The root's project and the settings decide how the folder is served, and the
        // root's project which packages a workspace has: a change there can call for
        // another server, and calls for a new listing at least.
        const projects = vscode.workspace.createFileSystemWatcher(new vscode.RelativePattern(folder, '{Project,JuliaProject}.toml'));
        const changed = () => {
            const now = this.serving();
            if (!this.server?.running) {
                this.combined = now.combined;
                later();
            } else if (model.folderChange({ combined: this.combined, environment: this.server.options.environment }, now) === 'restart') {
                this.restart();
            } else {
                later();
            }
        };
        projects.onDidChange(changed);
        projects.onDidCreate(changed);
        projects.onDidDelete(changed);
        const settings = vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('runtests', folder)) changed();
        });
        this.disposables.push(watcher, projects, settings, { dispose: () => clearTimeout(timer) });
    }

    // Whether the folder is served as a workspace of several packages, as the setting
    // `runtests.monorepo` and the folder's project say now.
    mode() {
        return model.isCombined(vscode.workspace.getConfiguration('runtests', this.folder).get('monorepo') ?? 'auto', this.root, read);
    }

    // How the folder would be served now: its mode, and the environment of its server.
    serving() {
        const combined = this.mode();
        const setting = vscode.workspace.getConfiguration('runtests', this.folder).get('environment');
        return { combined, environment: model.serverEnvironment({ root: this.root, combined, setting, read }) };
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
        const environment = model.serverEnvironment({ root: this.root, combined: this.combined, setting: config.get('environment'), read });
        const problem = model.configProblem(this.combined, config.get('config'));
        if (problem) {
            this.log.appendLine(`[${this.folder.name}] ${problem}`);
            vscode.window.showWarningMessage(`Runtests: ${problem}`);
        }
        this.server = new RuntestsServer({
            julia, juliaArgs: config.get('julia.args') ?? [], environment, root: this.root, combined: this.combined,
            config: config.get('config') && !this.combined ? path.resolve(this.root, config.get('config')) : undefined,
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
        // A server of several packages: a node for each package, its files under it.
        const groups = this.combined ? model.groupByPackage(listing.items, listing.packages ?? []) :
            [{ package: null, files: model.groupByFile(listing.items, listing.testdir) }];
        this.byKey.clear();
        this.keyById.clear();
        this.under.clear();
        const all = [];
        const nodes = [];
        for (const g of groups) {
            const fileNodes = [];
            const keys = [];
            for (const f of g.files) {
                const uri = vscode.Uri.file(f.file);
                const fileNode = this.ctrl.createTestItem(this.id('file', `${g.package ?? ''}/${f.relpath}`), f.relpath, uri);
                fileNode.children.replace(f.items.map(it => {
                    const key = model.itemKey(it);
                    const node = this.ctrl.createTestItem(this.id('item', key), it.name, uri);
                    node.range = new vscode.Range(it.line - 1, 0, it.end_line - 1, 0);
                    node.tags = it.tags.map(t => new vscode.TestTag(t));
                    node.description = describe(it);
                    this.byKey.set(key, node);
                    this.keyById.set(node.id, key);
                    this.under.set(node.id, [key]);
                    return node;
                }));
                const fileKeys = f.items.map(model.itemKey);
                this.under.set(fileNode.id, fileKeys);
                keys.push(...fileKeys);
                fileNodes.push(fileNode);
            }
            all.push(...keys);
            if (g.package === null) {
                nodes.push(...fileNodes);
            } else {
                const pkgNode = this.ctrl.createTestItem(this.id('package', g.package), g.package, vscode.Uri.file(g.root));
                pkgNode.children.replace(fileNodes);
                this.under.set(pkgNode.id, keys);
                nodes.push(pkgNode);
            }
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
        return (this.failed ?? []).map(k => this.byKey.get(model.itemKey(k))).filter(Boolean);
    }

    // The part of `request` that is this folder's, as item keys; `undefined` when
    // none of it is.
    keysFor(request) {
        const mine = node => this.under.has(node.id);
        const include = request.include?.filter(mine).map(n => n.id);
        const exclude = (request.exclude ?? []).filter(mine).map(n => n.id);
        if (request.include && include.length === 0) return undefined;
        return model.selectedKeys(include, exclude, this.under, this.all ?? []);
    }

    async run(request, run, token) {
        if (!this.all) await this.refresh();
        const keys = this.keysFor(request);
        if (keys === undefined || (keys !== null && keys.length === 0)) return;
        const targets = (keys ?? this.all ?? []).map(k => this.byKey.get(k)).filter(Boolean);
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
            await this.runOnServer(keys, run, token, targets);
        } finally {
            done();
        }
    }

    async runOnServer(keys, run, token, targets) {
        const server = this.ensureServer();
        const options = vscode.workspace.getConfiguration('runtests', this.folder).get('run.options') ?? {};
        // Stopped from wherever it was started, and from the run's own Stop.
        const cancels = [token.onCancellationRequested(() => server.cancel()),
            run.token.onCancellationRequested(() => server.cancel())];
        this.activeRun = run;
        let unknownSeen = false;
        const settled = new Set();
        try {
            const end = await server.run(keys, options, ev => {
                const item = ev.name !== undefined ? this.byKey.get(model.itemKey(ev)) : undefined;
                if (ev.event === 'run_started') {
                    for (const k of ev.unknown) {
                        const t = this.byKey.get(model.itemKey(k));
                        if (t) run.errored(t, new vscode.TestMessage('not in the suite any more'));
                        unknownSeen = true;
                    }
                    // Queued, but not what the run selected: outside its default group.
                    for (const k of model.unselected(targets.map(t => this.keyById.get(t.id)), ev)) {
                        const t = this.byKey.get(k);
                        if (t) run.skipped(t);
                        settled.add(k);
                    }
                } else if (ev.event === 'item_started') {
                    if (item) run.started(item);
                    else unknownSeen = true;
                } else if (ev.event === 'item_finished' && item) {
                    settled.add(model.itemKey(ev));
                    this.finish(run, item, ev);
                }
            });
            if (end.event === 'error' || end.event === 'exit' || end.state === 'error') {
                // What had an outcome keeps it; the rest could not run.
                const text = end.event === 'error' ? end.message : end.event === 'exit' ? end.error.message :
                    'the run stopped with an error; see the Runtests log';
                for (const t of targets) if (!settled.has(this.keyById.get(t.id))) run.errored(t, new vscode.TestMessage(text));
                run.appendOutput(model.crlf(`Runtests: ${text}\n`));
            } else {
                for (const k of end.not_run ?? []) {
                    const t = this.byKey.get(model.itemKey(k));
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

    // A new server, in the mode the folder has now, and a new listing.
    async restart() {
        this.combined = this.mode();
        if (this.server) await this.server.stop();
        this.server = null;
        await this.refresh();
    }

    dispose() {
        this.server?.stop();
        for (const d of this.disposables) d.dispose();
    }
}

// Whether the folder is served as a workspace of several packages: as the setting
// `runtests.monorepo` says, or, `auto`, when its project lists such members.
// A file's text, or null when there is none.
function read(file) {
    try {
        return fs.readFileSync(file, 'utf8');
    } catch {
        return null;
    }
}

// What the tree says beside an item's name: what sets it apart from the rest.
function describe(it) {
    const parts = [];
    if (it.tags.length) parts.push(it.tags.join(', '));
    if (it.sandbox) parts.push('sandbox');
    if (it.profile) parts.push(`profile ${it.profile}`);
    if (it.chain) parts.push(`chain ${it.chain}`);
    if (it.skip !== false) parts.push(it.skip === true ? 'skipped' : `skip if ${it.skip}`);
    return parts.join(' · ');
}

function deactivate() {}

module.exports = { activate, deactivate };
