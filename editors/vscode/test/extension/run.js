// Opens a VS Code of its own — a window, with its own settings and its own empty
// extensions directory, so that nothing it does touches the VS Code in daily use —
// on a package made for the test, and runs `index.js` in it. VS Code
// exits when the test is done, with its outcome.
//
//     node test/extension/run.js [path to VS Code's executable]
//
// The executable itself, not the `code` command, which hands a new window to the
// app and returns at once: the executable stays until the test is done and exits
// with its result.
'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const EXT = path.resolve(__dirname, '..', '..');
const REPO = path.resolve(EXT, '..', '..');
const code = process.argv[2] ??
    (process.platform === 'darwin' ? '/Applications/Visual Studio Code.app/Contents/MacOS/Code' : 'code');
const sep = process.platform === 'win32' ? ';' : ':';

const pkg = fs.mkdtempSync(path.join(os.tmpdir(), 'yatf-vscode-ext-'));
fs.writeFileSync(path.join(pkg, 'Project.toml'), 'name = "Shown"\nuuid = "0b0b0b0b-0000-4000-8000-00000000beef"\nversion = "0.1.0"\n');
fs.mkdirSync(path.join(pkg, 'src'));
fs.writeFileSync(path.join(pkg, 'src', 'Shown.jl'), 'module Shown\nend\n');
fs.mkdirSync(path.join(pkg, 'test'));
const item = (name, body, opts = '') => `@testitem "${name}" ${opts} begin\n    ${body}\nend\n`;
fs.writeFileSync(path.join(pkg, 'test', 'a_test.jl'),
    item('passes', '@test true') + item('fails', 'x = 1\n    @test x == 2') + item('tagged', '@test true', 'tags=[:fast]'));
// The server runs YATF from this checkout, and its workers find YATFWorkers through
// the load path, as the Julia tests arrange.
fs.mkdirSync(path.join(pkg, '.vscode'));
fs.writeFileSync(path.join(pkg, '.vscode', 'settings.json'), JSON.stringify({ 'yatf.environment': REPO }));

const user = fs.mkdtempSync(path.join(os.tmpdir(), 'yatf-vscode-user-'));
const extensions = fs.mkdtempSync(path.join(os.tmpdir(), 'yatf-vscode-extensions-'));
// Run from VS Code's own runtime in Node mode, this would start the editor as Node.
const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const result = spawnSync(code, [
    pkg, '--new-window', '--disable-extensions', '--skip-welcome', '--skip-release-notes',
    `--user-data-dir=${user}`, `--extensions-dir=${extensions}`, `--extensionDevelopmentPath=${EXT}`,
    `--extensionTestsPath=${path.join(__dirname, 'index.js')}`,
], {
    stdio: 'inherit',
    env: {
        ...env,
        JULIA_LOAD_PATH: [REPO, path.join(REPO, 'test'), ''].join(sep),
        YATF_RUNSTATE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), 'yatf-runs-')),
    },
});
fs.rmSync(pkg, { recursive: true, force: true });
fs.rmSync(user, { recursive: true, force: true });
fs.rmSync(extensions, { recursive: true, force: true });
process.exit(result.status ?? 1);
