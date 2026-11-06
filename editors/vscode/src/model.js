// What the extension decides without VS Code: how items group into packages and
// files, which items a Test Explorer selection means, and what an item's outcome
// shows. Plain data in and out, so it is tested without an editor.
'use strict';

const path = require('node:path');

// An item is known by its key: its package and its name, which together tell apart
// two items of one name in a server of several packages. No name holds a NUL.
const SEP = '\u0000';
const keyOf = (pkg, name) => `${pkg ?? ''}${SEP}${name}`;
const itemKey = it => keyOf(it.package, it.name);
/** A key as the protocol writes it: `{package, name}`. */
function keyObject(key) {
    const i = key.indexOf(SEP);
    return { package: key.slice(0, i), name: key.slice(i + 1) };
}

/**
 * The items of one package grouped by file, each file with its path relative to the
 * package's test directory, files and items in the order they appear. An item
 * declared twice is kept where the listing has it first: keys are the tree's ids, and
 * the listing's errors say where the other declaration is.
 * @param {Array<{package?: string, name: string, file: string, line: number}>} items
 * @param {string} testdir
 */
function groupByFile(items, testdir) {
    const files = new Map();
    const seen = new Set();
    for (const it of items) {
        if (seen.has(itemKey(it))) continue;
        seen.add(itemKey(it));
        let f = files.get(it.file);
        if (!f) {
            f = { file: it.file, relpath: path.relative(testdir, it.file), items: [] };
            files.set(it.file, f);
        }
        f.items.push(it);
    }
    const out = [...files.values()].sort((a, b) => a.relpath.localeCompare(b.relpath));
    for (const f of out) f.items.sort((a, b) => a.line - b.line);
    return out;
}

/**
 * The items of a server of several packages, package by package in the order the
 * listing gives them, each package's files as `groupByFile` makes them. A package
 * without items is left out.
 * @param {Array<{package: string, name: string, file: string, line: number}>} items
 * @param {Array<{name: string, root: string, testdir: string}>} packages
 */
function groupByPackage(items, packages) {
    return packages
        .map(p => ({ package: p.name, root: p.root, files: groupByFile(items.filter(it => it.package === p.name), p.testdir) }))
        .filter(g => g.files.length > 0);
}

/**
 * The item keys a run request means: every item under the included nodes, less
 * every item under the excluded ones. `null` means the whole suite, which is what
 * a request without `include` asks for when it excludes nothing.
 * @param {string[] | undefined} include  node ids, or undefined for everything
 * @param {string[]} exclude  node ids
 * @param {Map<string, string[]>} under  node id -> the keys of the items at or below it
 * @param {string[]} all  every item key
 * @returns {string[] | null}
 */
function selectedKeys(include, exclude, under, all) {
    if (include === undefined && exclude.length === 0) return null;
    const out = new Set();
    for (const id of include ?? []) for (const n of under.get(id) ?? []) out.add(n);
    if (include === undefined) for (const n of all) out.add(n);
    for (const id of exclude) for (const n of under.get(id) ?? []) out.delete(n);
    return [...out];
}

const STATE_WORDS = {
    timedout: 'timed out',
    broken_chain: 'did not run: an earlier item of its chain lost its worker',
    errored: 'errored',
    failed: 'failed',
};

/**
 * What an `item_finished` event shows: its kind (`passed`, `failed`, `errored` or
 * `skipped`), how long it took in milliseconds, and its messages, each with the
 * place it points at when it has one. A timeout or a dead worker has no failure of
 * its own to show, so the run's note, or the state in words, stands for it.
 * @param {{state: string, elapsed: number, note: string, failures: Array<{kind: string, message: string, file: string, line: number}>}} ev
 */
function outcome(ev) {
    const durationMs = Math.round((ev.elapsed ?? 0) * 1000);
    const messages = (ev.failures ?? []).map(f => ({ text: f.message, file: f.file || null, line: f.line }));
    switch (ev.state) {
        case 'passed':
            return { kind: 'passed', durationMs, messages: [] };
        case 'skipped':
        case 'cancelled':
            return { kind: 'skipped', durationMs, messages: [] };
        case 'failed':
            return { kind: 'failed', durationMs, messages: withFallback(messages, ev) };
        default:
            return { kind: 'errored', durationMs, messages: withFallback(messages, ev) };
    }
}

function withFallback(messages, ev) {
    if (messages.length > 0) return messages;
    return [{ text: ev.note || STATE_WORDS[ev.state] || ev.state, file: null, line: 0 }];
}

// Test output is written to a terminal, which wants CRLF line ends.
const crlf = text => text.replace(/\r?\n/g, '\r\n');

// The server writes in colour, for the terminal a run's output is shown in; an
// output channel shows the escape codes as they are, so it gets the text without.
const plain = text => text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');

/**
 * The keys an editor queued for a run that the run did not select: a run asked for
 * no items in particular selects the items of the suite's default group, which can
 * be fewer than the tree shows. Keys the suite does not have are left out; the run
 * says those are unknown.
 * @param {string[]} queued  the keys queued
 * @param {{items?: Array<{package: string, name: string}>, unknown?: Array<{package: string, name: string}>}} started
 *   the run's `run_started` event
 */
function unselected(queued, started) {
    const selected = new Set((started.items ?? []).map(itemKey));
    const unknown = new Set((started.unknown ?? []).map(itemKey));
    return queued.filter(k => !selected.has(k) && !unknown.has(k));
}

/**
 * A TOML document as nested objects, as far as a project file needs it: bare, quoted
 * and dotted keys; strings of either quote, on one line or several; arrays across
 * lines, with comments in them; inline tables; `[table]` and `[[array of tables]]`
 * headers, indented or not. A number, a boolean or a date stays its text. Throws on
 * what is not TOML that it reads.
 * @param {string} text
 * @returns {Record<string, any>}
 */
function parseToml(text) {
    let i = 0;
    const fail = what => { throw new Error(`not TOML: ${what}, at character ${i}`); };
    const at = re => { re.lastIndex = i; const m = re.exec(text); return m && m[0]; };
    const skipSpace = () => { i += at(/[ \t]*/y).length; };
    const skipComment = () => { if (text[i] === '#') i += at(/[^\r\n]*/y).length; };
    // What may come between the items of an array: spaces, comments and line ends.
    const skipBetween = () => {
        for (;;) {
            skipSpace();
            skipComment();
            if (text[i] === '\n' || text[i] === '\r') i++;
            else return;
        }
    };
    const endOfLine = () => {
        skipSpace();
        skipComment();
        if (i < text.length && text[i] !== '\n' && text[i] !== '\r') fail('more after a value');
    };
    const ESCAPES = { b: '\b', t: '\t', n: '\n', f: '\f', r: '\r', e: '\x1b', '"': '"', '\\': '\\' };
    function escaped() {
        const c = text[i + 1];
        if (c in ESCAPES) {
            i += 2;
            return ESCAPES[c];
        }
        const width = c === 'u' ? 4 : c === 'U' ? 8 : 0;
        const hex = text.slice(i + 2, i + 2 + width);
        if (width === 0 || !/^[0-9a-fA-F]+$/.test(hex) || hex.length !== width) fail('an escape');
        i += 2 + width;
        return String.fromCodePoint(parseInt(hex, 16));
    }
    // A multi-line string drops a line end right after its opening quotes, and may end
    // in up to two quotes of its own kind.
    function multiline(quote, escapes) {
        i += 3;
        i += at(/\r?\n/y)?.length ?? 0;
        let s = '';
        for (;;) {
            if (i >= text.length) fail('an unterminated string');
            if (text.startsWith(quote.repeat(3), i)) {
                const run = at(new RegExp(`${quote}{3,5}`, 'y'));
                i += run.length;
                return s + quote.repeat(run.length - 3);
            }
            if (escapes && text[i] === '\\') {
                const trim = at(/\\[ \t]*\r?\n\s*/y);
                if (trim) i += trim.length;
                else s += escaped();
                continue;
            }
            s += text[i++];
        }
    }
    function string() {
        const quote = text[i];
        if (text.startsWith(quote.repeat(3), i)) return multiline(quote, quote === '"');
        i++;
        let s = '';
        for (;;) {
            const c = text[i];
            if (c === undefined || c === '\n' || c === '\r') fail('an unterminated string');
            if (c === quote) {
                i++;
                return s;
            }
            if (quote === '"' && c === '\\') s += escaped();
            else {
                s += c;
                i++;
            }
        }
    }
    function key() {
        const parts = [];
        for (;;) {
            skipSpace();
            if (text[i] === '"' || text[i] === "'") parts.push(string());
            else {
                const bare = at(/[A-Za-z0-9_-]+/y);
                if (!bare) fail('a key');
                parts.push(bare);
                i += bare.length;
            }
            skipSpace();
            if (text[i] !== '.') return parts;
            i++;
        }
    }
    // The table at `path` in `t`, made where missing; through an array of tables, its last.
    function table(t, path) {
        for (const p of path) {
            if (!Object.hasOwn(t, p)) t[p] = {};
            t = Array.isArray(t[p]) ? t[p][t[p].length - 1] : t[p];
            if (typeof t !== 'object' || t === null || Array.isArray(t)) fail(`a value used as a table, ${p}`);
        }
        return t;
    }
    const assign = (t, path, v) => { table(t, path.slice(0, -1))[path[path.length - 1]] = v; };
    function value() {
        const c = text[i];
        if (c === '"' || c === "'") return string();
        if (c === '[') {
            i++;
            const items = [];
            for (;;) {
                skipBetween();
                if (text[i] === ']') break;
                items.push(value());
                skipBetween();
                if (text[i] === ',') i++;
                else if (text[i] !== ']') fail('an array');
            }
            i++;
            return items;
        }
        if (c === '{') {
            i++;
            const t = {};
            skipSpace();
            if (text[i] === '}') {
                i++;
                return t;
            }
            for (;;) {
                const k = key();
                if (text[i] !== '=') fail('an inline table');
                i++;
                skipSpace();
                assign(t, k, value());
                skipSpace();
                if (text[i] === ',') {
                    i++;
                    continue;
                }
                if (text[i] !== '}') fail('an inline table');
                i++;
                return t;
            }
        }
        const word = at(/[^,\]}#\r\n]+/y);
        if (!word || !word.trim()) fail('a value');
        i += word.length;
        return word.trim();
    }
    const root = {};
    let current = root;
    for (;;) {
        skipBetween();
        if (i >= text.length) return root;
        if (text[i] === '[') {
            const many = text[i + 1] === '[';
            i += many ? 2 : 1;
            const path = key();
            if (!text.startsWith(many ? ']]' : ']', i)) fail('a table header');
            i += many ? 2 : 1;
            endOfLine();
            if (many) {
                const parent = table(root, path.slice(0, -1)), last = path[path.length - 1];
                if (!Object.hasOwn(parent, last)) parent[last] = [];
                if (!Array.isArray(parent[last])) fail(`a table that is also an array of tables, ${last}`);
                parent[last].push(current = {});
            } else {
                current = table(root, path);
            }
            continue;
        }
        const path = key();
        if (text[i] !== '=') fail('a key without a value');
        i++;
        skipSpace();
        assign(current, path, value());
        endOfLine();
    }
}

// A project file's tables, or null for a file that is not TOML, which the server says.
function readProject(projectToml) {
    try {
        return parseToml(projectToml);
    } catch {
        return null;
    }
}

/**
 * The member directories that `projects` of `[workspace]` of a Project.toml lists, as
 * written, with `/` between their parts.
 * @param {string} projectToml
 * @returns {string[]}
 */
function workspaceMembers(projectToml) {
    const projects = readProject(projectToml)?.workspace?.projects;
    if (!Array.isArray(projects)) return [];
    return projects.filter(p => typeof p === 'string').map(p => p.replace(/\\/g, '/').replace(/^\.\//, ''));
}

/**
 * Whether a folder is the root of a workspace of several packages, to serve with
 * `Runtests.serve_mono`: its project lists a member other than its own `test`.
 * @param {string} projectToml  the text of the folder's Project.toml
 */
function isMonorepo(projectToml) {
    return workspaceMembers(projectToml).some(m => m !== 'test' && !m.startsWith('test/'));
}

/**
 * The text of the project in `dir`, or null when it has none. Julia reads
 * JuliaProject.toml before Project.toml.
 * @param {string} dir
 * @param {(file: string) => string | null} read  a file's text, or null when there is none
 */
const projectText = (dir, read) => read(path.join(dir, 'JuliaProject.toml')) ?? read(path.join(dir, 'Project.toml'));

/**
 * Whether the folder at `root` is served as a workspace of several packages: as the
 * setting `runtests.monorepo` says, and for `auto`, as the folder's project says.
 * @param {string} setting  `auto`, `on` or `off`
 * @param {string} root
 * @param {(file: string) => string | null} read  a file's text, or null when there is none
 */
function isCombined(setting, root, read) {
    if (setting === 'on') return true;
    if (setting === 'off') return false;
    return isMonorepo(projectText(root, read) ?? '');
}

const RUNTESTS_UUID = '632efd68-cd41-4e05-bd25-b86dc2150078';

/**
 * Whether a project can load Runtests: its `[deps]` table names it.
 * @param {string} projectToml
 */
function declaresRuntests(projectToml) {
    return readProject(projectToml)?.deps?.Runtests === RUNTESTS_UUID;
}

/**
 * The environment a folder's server runs in. The setting's, when given. For a folder
 * of one package: its `test` when that has a project, the folder otherwise. For a
 * workspace of several: the first of the root's `test`, the root and each member's
 * `test` whose project has Runtests in `[deps]`, because the server must load Runtests
 * and a workspace can have it only in its members' test projects; the root when none
 * has it.
 * @param {{root: string, combined: boolean, setting?: string, read: (file: string) => string | null}} o
 *   `read` gives a file's text, or null when there is none.
 * @returns {string}
 */
function serverEnvironment(o) {
    if (o.setting) return path.resolve(o.root, o.setting);
    const project = dir => projectText(dir, o.read);
    const test = path.join(o.root, 'test');
    if (!o.combined) return project(test) !== null ? test : o.root;
    const candidates = [test, o.root, ...workspaceMembers(project(o.root) ?? '').map(m => path.join(o.root, m, 'test'))];
    return candidates.find(dir => declaresRuntests(project(dir) ?? '')) ?? o.root;
}

/**
 * What a change to a folder's project or settings calls for: `restart`, a new server,
 * when the mode or the environment its server would run in changed, and `refresh`, a
 * new listing, otherwise, since the members of a workspace can have changed.
 * @param {{combined: boolean, environment: string}} serving  the server that runs
 * @param {{combined: boolean, environment: string}} now  what the folder says now
 */
function folderChange(serving, now) {
    return serving.combined !== now.combined || serving.environment !== now.environment ? 'restart' : 'refresh';
}

/**
 * Why the server does not use `runtests.config`, or null when it does. The file
 * replaces the `test/TestItems.toml` of one package, and the packages of a workspace
 * each read their own.
 * @param {boolean} combined
 * @param {string | undefined} config
 */
function configProblem(combined, config) {
    return combined && config ?
        '`runtests.config` is not used: the packages of a workspace each read their own test/TestItems.toml' :
        null;
}

module.exports = {
    keyOf, itemKey, keyObject, groupByFile, groupByPackage, selectedKeys, outcome, crlf, plain, unselected,
    parseToml, workspaceMembers, isMonorepo, isCombined, declaresRuntests, serverEnvironment, folderChange, configProblem,
};
