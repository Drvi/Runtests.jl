// A Runtests server: the Julia process `Runtests.serve` runs, and the protocol spoken with
// it — one JSON object per line, commands in, events out, everything written for
// people on stderr. No VS Code here, so it is tested against a real server.
'use strict';

const { spawn } = require('node:child_process');
const readline = require('node:readline');
const { EventEmitter } = require('node:events');

const PROTOCOL = 1;

class RuntestsServer extends EventEmitter {
    /**
     * @param {{julia: string, juliaArgs?: string[], environment: string, root: string,
     *          config?: string, env?: NodeJS.ProcessEnv, onLog?: (line: string) => void}} options
     *   `julia` and `juliaArgs` start Julia (`juliaArgs` go first, so `+1.12` works
     *   for juliaup); `environment` is the project it runs in, which must have
     *   Runtests; `root` the package whose suite it serves; `config` a file every
     *   listing and run reads in place of `test/TestItems.toml`.
     */
    constructor(options) {
        super();
        this.options = options;
        this.onLog = options.onLog ?? (() => {});
        this.proc = null;
        this.nextId = 1;
        this.pending = new Map();   // id -> the handler of that command's events
        this.hello = null;
    }

    get running() { return this.proc !== null; }

    /** Start the process, and resolve with its `hello` once it has said it. */
    start() {
        if (this.proc) return this.ready;
        const o = this.options;
        // In colour: what it writes for people is shown in a terminal, which renders it.
        const args = [...(o.juliaArgs ?? []), `--project=${o.environment}`, '--startup-file=no', '--color=yes',
            '-e', 'using Runtests; Runtests.serve(ARGS[1]; config = get(ARGS, 2, nothing))', o.root,
            ...(o.config ? [o.config] : [])];
        this.onLog(`starting: ${o.julia} ${args.map(a => (/\s/.test(a) ? JSON.stringify(a) : a)).join(' ')}`);
        const proc = spawn(o.julia, args, { cwd: o.root, env: o.env ?? process.env, stdio: ['pipe', 'pipe', 'pipe'] });
        this.proc = proc;
        this.ready = new Promise((resolve, reject) => {
            this.once('hello', resolve);
            proc.once('error', reject);                   // no such julia, say
            proc.once('exit', (code, signal) =>
                reject(new Error(`the Runtests server exited before it was ready (${signal ?? `code ${code}`}); see its log`)));
        });
        // A process that could not be started never exits, so it is forgotten here,
        // and the next `start` tries again.
        proc.on('error', err => {
            if (this.proc === proc) this.proc = null;
            this.onLog(`could not start ${o.julia}: ${err.message}`);
        });
        readline.createInterface({ input: proc.stdout }).on('line', line => this.dispatch(line));
        readline.createInterface({ input: proc.stderr }).on('line', line => this.onLog(line));
        proc.on('exit', (code, signal) => {
            this.proc = null;
            this.hello = null;
            const gone = new Error(`the Runtests server exited (${signal ?? `code ${code}`})`);
            for (const handler of this.pending.values()) handler({ event: 'exit', error: gone });
            this.pending.clear();
            this.emit('exit', code, signal);
        });
        return this.ready;
    }

    dispatch(line) {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch {
            this.onLog(`not an event: ${line}`);
            return;
        }
        if (ev.event === 'hello') {
            if (ev.protocol !== PROTOCOL) {
                this.onLog(`the server speaks protocol ${ev.protocol}; this extension speaks ${PROTOCOL}`);
            }
            this.hello = ev;
            this.emit('hello', ev);
        }
        const handler = ev.id !== undefined ? this.pending.get(ev.id) : undefined;
        if (handler) handler(ev);
        else if (ev.event === 'error') this.onLog(`server: ${ev.message}`);
        this.emit('event', ev);
    }

    send(command) {
        if (!this.proc) throw new Error('the Runtests server is not running');
        this.proc.stdin.write(JSON.stringify(command) + '\n');
    }

    /** The suite's items and problems: the `items` event, or a rejection saying why not. */
    async list() {
        await this.start();
        const id = this.nextId++;
        return new Promise((resolve, reject) => {
            this.pending.set(id, ev => {
                this.pending.delete(id);
                if (ev.event === 'items') resolve(ev);
                else reject(Object.assign(new Error(ev.error?.message ?? ev.message), { errors: ev.errors ?? [] }));
            });
            this.send({ id, command: 'list' });
        });
    }

    /**
     * Run `names` (every item when null), handing each of the run's events to
     * `onEvent` as it comes. Resolves with the event that ends it: `run_finished`,
     * an `error` when the run could not start, or `exit` when the server died.
     */
    async run(names, options, onEvent) {
        await this.start();
        const id = this.nextId++;
        return new Promise(resolve => {
            let started = false;
            this.pending.set(id, ev => {
                if (ev.event === 'run_started') started = true;
                onEvent(ev);
                const over = ev.event === 'run_finished' || ev.event === 'exit' || (ev.event === 'error' && !started);
                if (over) {
                    this.pending.delete(id);
                    resolve(ev);
                }
            });
            const command = { id, command: 'run', options: options ?? {} };
            if (names !== null) command.names = names;
            this.send(command);
        });
    }

    cancel() {
        if (this.proc) this.send({ command: 'cancel' });
    }

    /** Ask the server to stop, and kill it when it has not within `timeoutMs`. */
    async stop(timeoutMs = 5000) {
        const proc = this.proc;
        if (!proc) return;
        const exited = new Promise(resolve => proc.once('exit', resolve));
        try {
            this.send({ command: 'shutdown' });
        } catch { /* already going */ }
        const timer = setTimeout(() => proc.kill(), timeoutMs);
        await exited;
        clearTimeout(timer);
    }
}

module.exports = { RuntestsServer, PROTOCOL };
