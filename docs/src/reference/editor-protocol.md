# [Editor protocol](@id editor-protocol)

An editor drives a Runtests server over the standard streams of the server process. The editor writes commands to stdin and reads events from stdout, one JSON object on each line in each direction. Everything written for people goes to stderr, which an editor can show as a log. This includes the lines of the run, the output of Pkg and the output of the test items.

## Start the server

```sh
julia --project=<an environment with Runtests> -e 'using Runtests; Runtests.serve("<package>")'
```

`Runtests.serve("<package>"; config = "<file>")` makes every listing and run of the session read `<file>` in place of `test/TestItems.toml`. A relative path is relative to the directory in which the server starts.

`serve` takes over the stdout of the process. After it starts, anything else written to stdout goes to stderr, from Julia or from C. Thus a stray `println` cannot get into the stream of events. `serve` returns when stdin ends or a `shutdown` command arrives. It cancels a run in progress first. One server serves one package, and runs one run at a time.

`Runtests.serve_mono("<workspace root>")` serves the packages of a workspace, as [`runtests_mono`](@ref monorepos) runs them. Its listing holds the items of every package, and each run is a combined run. Two items of two packages can have the same name, so an item is known by its key: the name of its package and its own name.

The protocol version is `3`, and the `hello` event gives it. A change that can break an editor written against the protocol increases the version.

## Commands

Every command is an object with a `command` field. It can have an `id` of any JSON value. Replies echo a non-null `id` when the command could be read; an absent or `null` ID is omitted from replies. Events for a run keep the ID of its `run` command.

| Command | Fields | Answer |
|:--------|:-------|:-------|
| `list` | none | `items`, or `error`. |
| `run` | `items`: item keys, each an object with `package` and `name`. `names`: exact item names, of every package, which `serve_mono` does not take. Without either, the run selects what a run selects when nothing else selects. `options`: an object of configuration values. | `run_started`, then `item_started` and `item_finished` for each attempt, then `run_finished`. Or `error`. |
| `cancel` | none | No separate acknowledgement: the run ends with `run_finished`, `state` `cancelled`, and the original `run` ID. An `error` when nothing runs carries the `cancel` ID. |
| `shutdown` | none | `bye`, without an ID. |

### The `options` field

`options` takes these keywords of `runtests`, with the same meaning and the same validation:

| Keywords | Value |
|:---------|:------|
| `workers`, `threads`, `retries`, `memory_threshold` | As for `runtests`. |
| `timeout`, `init_timeout`, `test_end_timeout` | Seconds. |
| `failfast`, `item_failfast`, `verbose`, `full_stacktraces`, `coverage` | `true` or `false`. |
| `logs` | A string, for example `"batched"`. |

These keys also apply:

- `seed` is an integer, or the `"0x…"` text that `run_started` gives. JSON integers stop at 2^63, so the text form can hold every seed.
- `group` is a group of `[groups]`, or `"all"` for the whole suite.
- `replay` is the path of a run state to run again.

Other run settings come from the configuration file and environment variables, as for any run. For example, `artifacts_timeout` is set in `[run]` or through `RUNTESTS_ARTIFACTS_TIMEOUT`; it is not accepted in `options`.

### Selection

An editor selects files, folders or tags by sending the keys of the items in them, from its last `list`. `run_started` lists the items that the run selected. The editor compares this list with what it asked for. A key that the suite does not have goes into the `unknown` field of `run_started`, and the other items still run. When none of the keys exists, the answer is an `error`.

## Events

Every event is an object with an `event` field. Replies carry IDs as described above; `hello` and `bye` have no ID. The server writes one event on each line of stdout. The first event is `hello`, and the last event is `bye`.

### hello

The first line, before any command. Its fields are `protocol`, the `runtests` and `julia` versions, the `pid` of the server, the `root` of the package or workspace, `config`, `combined` and `packages`. `config` is the file that the server reads in place of `test/TestItems.toml`, or `null`. `combined` is `true` for `serve_mono`. `packages` holds the `name` and `root` of each package that the server serves.

### items

The answer to `list`. Its fields are `root`, `testdir`, `packages`, `items`, `errors` and `failed`. `testdir` is `null` for `serve_mono`. `packages` holds the `name`, `root` and `testdir` of each package. `failed` holds the keys of the items that are failing, which are the items that `Runtests.runtestsf()` runs in their package. The last run that ran an item to a verdict decides, whether that run came from the editor, the terminal or a replay. A run that stopped before it reached an item leaves the verdict as it was.

Each item in `items` has these fields:

| Field | Meaning |
|:------|:--------|
| `package` | The name of the package of the item. With `name`, its key, which identifies an item everywhere in the protocol. |
| `name` | Unique in its package. |
| `file`, `line` | The absolute path, and the line of the `@testitem`. |
| `end_line` | The line before the next item in the file, or the last line of the file. These are the lines where the item is the one at the cursor. |
| `tags`, `setups` | Strings. |
| `profile` | The profile from `profile = :name`, or `null` for the default profile. |
| `sandbox` | `true` for an item with `sandbox = true`, which runs alone in a process of its own. |
| `environment` | The absolute path of the environment directory of the item's file, or `null` for the test environment. |
| `chain` | The name of the chain, or `null`. |
| `skip` | `true`, `false`, or the text of the expression that the worker evaluates. |
| `timeout`, `retries`, `failfast` | The value of the item, or `null` for the value of the run. |

`errors` holds every problem that a run refuses to start on. Examples are a file that does not parse, a name that two items use, and a value that `TestItems.toml` does not accept. For `serve_mono`, it also holds what stops a combined run: two setups of one name, and an import that the test environment of its own package cannot load. Each error has a `file`, a `line` (0 when there is none) and a `message`. The items still come from every file that parses.

### run_started

| Field | Meaning |
|:------|:--------|
| `items` | The keys of the items that will run, in the order of the plan. |
| `workers` | The number of workers, or 0 for a run in the process of the server. |
| `seed` | The seed of the run, as `"0x…"` text. |
| `unknown` | The keys of the command that the suite does not have. |

### item_started

| Field | Meaning |
|:------|:--------|
| `package`, `name`, `file`, `line` | The item. |
| `attempt` | The number of the attempt, from 1. |
| `attempts` | The most attempts that the item gets. |
| `worker` | The worker slot, from 1, or 0 for an outcome recorded before a worker ran the item, such as a broken chain. |
| `pid` | The ID of the process of the worker, or 0 when the worker did not start. |

### item_finished

It has the fields of `item_started`, and these:

| Field | Meaning |
|:------|:--------|
| `state` | `passed`, `failed`, `errored`, `timedout`, `skipped`, `broken_chain` or `cancelled`. |
| `elapsed`, `compile` | Seconds, as the item measured them. For an outcome that the run decided, the time that the item held its worker. |
| `note` | What the run says about the attempt, for example that a retry follows. Often empty. |
| `log` | The file with captured item output, or `null` when no nonempty log exists. With `logs = "eager"`, output goes to stderr without a per-item log. |
| `failures` | Each failed or erroring test: `kind` (`fail` or `error`), `message` as `Test` shows it, `file` and `line`. |

An item that is retried, or that runs again with its chain, has an `item_started` and an `item_finished` for each attempt. The latest is its current state, and the last one before `run_finished` is its outcome.

`item_finished` reports the verdict before [failure-artifact producers](@ref evidence) finish. Wait for `run_finished` before copying the complete run bundle.

### run_finished

Its fields are these:

- `state`: `passed`, `failed`, `cancelled`, `stalled` or `error`. `stalled` means that the run stopped as hung. `error` comes after an `error` event that says why.
- `counts`: the number of items in each state.
- `not_run`: the keys of the items that never finished.
- `elapsed`: seconds.
- `runstate`: the run state file of a run of one package, or `null`.
- `runstates`: the run state of each package, each a `package` and a `path`. A combined run writes one for each package. The `path` is `null` when the run state could not be written.
- `logdir`: the directory of the item logs. Normally these stay beside the run state and follow its [retention rules](@ref retention). Only fallback logs in temporary storage are removed when the next run starts or the server stops.

If execution fails before a run can be initialized, `run_finished` has only `state` and the run's ID, when supplied. The other fields above are absent.

### error

Its fields are `message`, and `errors` when a run did not start because the suite does not parse. `errors` has the same form as in `items`. The server answers each of these problems with an `error`, and continues:

- a command that is not JSON, not an object, not a command, or not a command that the server knows,
- a field of the wrong type,
- a key in `options` that `run` does not take,
- a second `run` while a run is in progress,
- a `cancel` with nothing to cancel.

### bye

The last line. The server writes it when stdin ends or after a `shutdown` command. Before it writes `bye`, the server cancels a run in progress and waits for the run to stop.

## A session

```text
→ {"id":1,"command":"list"}
← {"event":"items","id":1,"root":"/pkg","testdir":"/pkg/test","packages":[…],"items":[{"package":"Pkg1","name":"adds","file":"/pkg/test/a_test.jl","line":1,"end_line":4,…}],"errors":[],"failed":[]}
→ {"id":2,"command":"run","items":[{"package":"Pkg1","name":"adds"}],"options":{"workers":1}}
← {"event":"run_started","id":2,"items":[{"package":"Pkg1","name":"adds"}],"workers":1,"seed":"0x0223a77cb668dc62","unknown":[]}
← {"event":"item_started","id":2,"package":"Pkg1","name":"adds","file":"/pkg/test/a_test.jl","line":1,"attempt":1,"attempts":1,"worker":1,"pid":4242}
← {"event":"item_finished","id":2,"package":"Pkg1","name":"adds",…,"state":"passed","elapsed":0.03,"compile":0.02,"note":"","log":null,"failures":[]}
← {"event":"run_finished","id":2,"state":"passed","counts":{"passed":1,…},"not_run":[],"elapsed":2.1,"runstate":"…","runstates":[…],"logdir":"…"}
→ {"command":"shutdown"}
← {"event":"bye"}
```
