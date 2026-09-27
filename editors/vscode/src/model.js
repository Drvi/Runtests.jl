// What the extension decides without VS Code: how items group into files, which
// item names a Test Explorer selection means, and what an item's outcome shows.
// Plain data in and out, so it is tested without an editor.
'use strict';

const path = require('node:path');

/**
 * The items of a listing grouped by file, each file with its path relative to the
 * test directory, files and items in the order they appear.
 * @param {Array<{name: string, file: string, line: number}>} items
 * @param {string} testdir
 */
function groupByFile(items, testdir) {
    const files = new Map();
    for (const it of items) {
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
 * The item names a run request means: every item under the included nodes, less
 * every item under the excluded ones. `null` means the whole suite, which is what
 * a request without `include` asks for when it excludes nothing.
 * @param {string[] | undefined} include  node ids, or undefined for everything
 * @param {string[]} exclude  node ids
 * @param {Map<string, string[]>} under  node id -> the names of the items at or below it
 * @param {string[]} all  every item name
 * @returns {string[] | null}
 */
function selectedNames(include, exclude, under, all) {
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

module.exports = { groupByFile, selectedNames, outcome, crlf, plain };
