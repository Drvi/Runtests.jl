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

It starts a Runtests server per workspace folder with a test suite (`Runtests.serve`,
[the editor protocol](../../docs/editor-protocol.md)) and speaks to it over its
standard streams. Everything the server writes for people is also in the **Runtests**
output channel, runs or not.

## Trying it

It is plain JavaScript with no dependencies: nothing to build.

- **From this checkout:** open `editors/vscode` in VS Code and press F5. In the
  window that opens, open a package tested with Runtests.
- **Installed for yourself:** link the directory into VS Code's extensions and
  reload the window:

  ```sh
  ln -s "$PWD/editors/vscode" ~/.vscode/extensions/runtests.runtests-0.1.0
  ```

The package's test environment must have Runtests: the server runs in
`test/Project.toml`'s environment when there is one, and the package's otherwise.

## Settings

| Setting | |
|---|---|
| `runtests.julia.executable` | the `julia` that runs the server; by default the Julia extension's `julia.executablePath`, or `julia` on the `PATH` |
| `runtests.julia.args` | arguments given to `julia` first, such as `["+1.12"]` for a juliaup channel |
| `runtests.environment` | the environment the server runs in, relative to the folder |
| `runtests.run.options` | settings sent with every run, such as `{"workers": 2}` |

Everything else a run takes comes from `test/TestItems.toml`, as it does for
`Runtests.runtests()`.

Commands: **Runtests: Run Failed Tests**, **Runtests: Restart Server** (after changing the
settings above, or Runtests itself) and **Runtests: Show Log**.

## What it does not do yet

No debugging and no coverage view. The
Julia extension finds `@testitem`s too and shows them in a tree of its own, run by
its own runner; items with Runtests' keywords (`timeout`, `retries`, `chain`, `sandbox`,
`failfast`) are errors there. `issues/editor-protocol.md` has the details.

## Tests

```sh
node --test test/*.test.js          # the model, and the protocol against a real server
node test/extension/run.js          # inside VS Code: a window with its own settings and extensions
```

Without Node on the `PATH`, VS Code's own runtime does:
`ELECTRON_RUN_AS_NODE=1 "/Applications/Visual Studio Code.app/Contents/MacOS/Code" --test test/*.test.js`.
The server tests start `julia` from the `PATH`, or `RUNTESTS_TEST_JULIA`.
