# [Use an editor](@id editors)

Runtests has an extension for VS Code, and a server that any editor can drive. This page tells you how to install the extension and what it does.

## The VS Code extension

The extension shows the test items of a Julia package in the Test Explorer of VS Code, and runs them there. It shows each file under `test/` with its items. You can run items from the tree or from the gutter next to the code. Results show while the run goes on, and a failure is marked at the line of the `@test` that failed. Cancel stops the run and its workers at once.

The output of a run goes to the Test Results panel. It is the output that Runtests writes in a terminal, with colors. The `logs` value in `runtests.run.options` controls which item output the panel shows, as it does for `runtests`.

The Run Failed Tests button in the toolbar of the Test Explorer runs what `Runtests.runtestsf()` runs. These are the items whose last run did not pass them, from the editor, the terminal or CI. The Rerun Failed Tests command of VS Code knows only the runs of this window.

### Install the extension

The extension is plain JavaScript with no dependencies, so there is nothing to build. The extension is in `editors/vscode` of the Runtests repository. Use one of these two ways:

1. To try it from a checkout, open `editors/vscode` in VS Code and press F5. In the window that opens, open a package that uses Runtests.
2. To install it for yourself, link the directory into the extensions of VS Code, and reload the window:

   ```sh
   ln -s "$PWD/editors/vscode" ~/.vscode/extensions/runtests.runtests-0.1.0
   ```

The server's environment must be able to run `using Runtests`. By default, the server uses `test/Project.toml` when there is one, and the package's environment otherwise. If Runtests is only in the package's `[extras]` and `[targets]`, it is not importable from the package environment. Set `runtests.environment` to an environment that contains Runtests; the server will still build the package's test environment for the tests.

### VS Code settings of the extension

| VS Code setting | Meaning |
|:--------|:--------|
| `runtests.julia.executable` | The `julia` that runs the server. By default, the `julia.executablePath` of the Julia extension, or `julia` on the `PATH`. |
| `runtests.julia.args` | Arguments that go to `julia` first, for example `["+1.12"]` for a juliaup channel. |
| `runtests.environment` | The environment that the server runs in, as an absolute path or relative to the folder. It must contain Runtests. |
| `runtests.run.options` | The [editor protocol's run options](@ref editor-protocol) sent with every run, for example `{"workers": 2}`. |
| `runtests.config` | A configuration file to read in place of `test/TestItems.toml`, relative to the folder. Restart the server after you change it. |

Other run settings come from the configuration file and environment variables, as for `Runtests.runtests()`. For example, set `artifacts_timeout` in `[run]` or `RUNTESTS_ARTIFACTS_TIMEOUT`; the editor's `options` field does not accept it.

The extension has three commands: Runtests: Run Failed Tests, Runtests: Restart Server and Runtests: Show Log. Restart the server after you change the VS Code settings above or update Runtests.

### What the extension does not do

The extension has no debugger and no coverage view. The Julia extension also finds `@testitem` declarations, and shows them in its own tree, run by its own runner. Items with the keywords of Runtests (`timeout`, `retries`, `chain`, `sandbox`, `failfast`) are errors there.

## Drive Runtests from another editor

`Runtests.serve(path)` lets an editor drive the suite of a package. The server lists the test items with their locations and keywords. It runs the items that the editor asks for, a group, or a replay of a run state. It reports the start and the outcome of each item while the run goes on, and cancels a run when the editor asks.

The server uses one JSON object for each line. Commands come on stdin, and events go to stdout. Everything written for people goes to stderr.

```sh
cd MyPackage && julia --project=test -e 'using Runtests; Runtests.serve()'
```

[The editor protocol](@ref editor-protocol) describes each command and event.
