# Runtests for VS Code

Shows a Julia package's Runtests test items in the Test Explorer and runs them there:
each file under `test/` with its items, run from the tree or the gutter, results as
they come in, a failure marked at the line of the `@test` that failed, and Cancel
stopping the run and its workers at once.

A run's output, in the Test Results panel VS Code opens when a run starts, is what
Runtests writes in a terminal, colours included: each item as it starts and ends, the
failures with the output of the items that had them, and the summary. `logs` in
`runtests.run.options` asks for more: `"batched"` for every item's output as it ends,
`"eager"` as it is written.

**Run Failed Tests**, in the Test Explorer's toolbar, runs what is failing, as
`Runtests.runtestsf()` does: every item whose last run, from the editor, the terminal or
CI, did not pass it. Each item keeps its own verdict, so running one of several
failures leaves the others failing. VS Code's own *Rerun Failed Tests* knows only the
runs of this window.

It starts a Runtests server per workspace folder with a test suite (`Runtests.serve`)
and speaks to it over its standard streams, one JSON object per line. Everything the
server writes for people is also in the **Runtests** output channel, runs or not.

A folder that is the root of a Julia workspace of several packages, a monorepo, is
served by `Runtests.serve_mono`: the items of every package in one tree, under a node
for each package, and each run a combined run, as `Runtests.runtests_mono()` runs it.
The folder is taken for one when its `Project.toml` lists workspace members other
than its own `test`; `runtests.monorepo` says otherwise.

## Trying it

It is plain JavaScript with no dependencies: nothing to build.

- **From this checkout:** open `editors/vscode` in VS Code and press F5. In the
  window that opens, open a package tested with Runtests.
- **Installed for yourself:** link the directory into VS Code's extensions and
  reload the window:

  ```sh
  ln -s "$PWD/editors/vscode" ~/.vscode/extensions/runtests.runtests-0.1.0
  ```

The server runs in an environment that has Runtests. For a folder of one package, it
is `test/Project.toml`'s environment when there is one, and the package's otherwise.
For a workspace of several packages, it is the first of the root's `test`, the root
and the `test` of each member that has Runtests in `[deps]`. The setting
`runtests.environment` replaces this choice.

## Settings

| Setting | |
|---|---|
| `runtests.julia.executable` | the `julia` that runs the server; by default the Julia extension's `julia.executablePath`, or `julia` on the `PATH` |
| `runtests.julia.args` | arguments given to `julia` first, such as `["+1.12"]` for a juliaup channel |
| `runtests.environment` | the environment the server runs in, relative to the folder |
| `runtests.monorepo` | `auto`, `on` or `off`: serve the folder as a workspace of several packages; `auto` when its `Project.toml` lists members other than its `test`. The server restarts when this setting, or the folder's `Project.toml`, changes the choice |
| `runtests.run.options` | settings sent with every run, such as `{"workers": 2}` |
| `runtests.config` | a config file read in place of `test/TestItems.toml`, relative to the folder, for listing and every run; **Runtests: Restart Server** after changing it. A workspace of several packages does not use it, because each package reads its own `test/TestItems.toml`. The extension then shows a warning |

Everything else a run takes comes from `test/TestItems.toml`, as it does for
`Runtests.runtests()`.

Commands: **Runtests: Run Failed Tests**, **Runtests: Restart Server** (after changing the
settings above, or Runtests itself) and **Runtests: Show Log**.

## What it does not do

No debugging and no coverage view. The Julia extension finds `@testitem`s too and
shows them in a tree of its own, run by its own runner; items with Runtests' keywords
(`timeout`, `retries`, `chain`, `sandbox`, `failfast`) are errors there.

## Tests

```sh
node --test test/*.test.js          # the model, and the protocol against a real server
node test/extension/run.js          # inside VS Code: a window with its own settings and extensions
```

Without Node on the `PATH`, VS Code's own runtime does:
`ELECTRON_RUN_AS_NODE=1 "/Applications/Visual Studio Code.app/Contents/MacOS/Code" --test test/*.test.js`.
The server tests start `julia` from the `PATH`, or `RUNTESTS_TEST_JULIA`.
