# [Output](@id output)

This page describes the output of a run, in five parts. These are the opening block, the lines of the run, the block of a failed item, the closing block and the dry-run plan. The examples come from a small suite. Times and memory depend on the suite and on the machine.

## The opening block

```text
┌ [TEST] v0.1.0 · julia 1.13.3 · 6 test items in 2 files · seed 0x522fb3b30334cd75 · 2 workers · threads 2,1
│ env: /var/folders/…/jl_7AEUWb/Project.toml
└ startup: scan 0.0s · plan 0.1s · setup 1.2s
```

The first line gives the versions of Runtests and Julia, and the number of selected items and files. It also gives the seed, the number of workers and their threads. It names these values too, when they apply:

- the selection, for example `matching tags = [:fast]`,
- the group and what selected it,
- the Julia flags of the workers that a plain `julia` does not have, for example `--check-bounds=yes -O1`,
- the environment variables that set configuration values,
- the source of the `coverage` value.

The `env` line is the path of the test environment. The `startup` line gives the time to find and parse the test files (`scan`), to make the plan and to set up the environment.

## The lines of the run

Workers, items and the run itself each print lines of one shape:

```text
⚪ w0 · 14:52:16 · INFO · 0/6 · 0 failed · 0/2 workers · tree mem 920M (max 920M) · child max 449M · mem 82% · cpu  5.5/18 · testing 0s
⚫ w1 · 14:52:16 · UP   · pid 35898 · threads 2,1
🔵 w1 · 14:52:16 · RUN  · 1/6 · "slow thing" · at test/sub/b_test.jl:9
🟢 w1 · 14:52:16 · DONE · 1/6 · "slow thing" · PASS ·  0.0s (94% compile) · maxrss 0.3 GiB
⚫ w1 · 14:52:16 · EXIT · pid 35898 · 3 items · 0.3s
```

Each line starts with a mark, the worker and the time. The worker is `w1`, `w2` and so on, and `w0` is the coordinator. The marks have these meanings:

| Mark | Meaning |
|:-----|:--------|
| ⚫ | A worker starts (`UP`) or ends (`EXIT`). |
| 🔵 | An item starts (`RUN`). |
| 🟢 | An item passed. |
| 🔴 | An item failed, errored or timed out. |
| 🟡 | An item was skipped or was never reached. |
| ⚪ | The progress line of the run (`INFO`). |

An `UP` line gives the process ID and the threads of the worker. It also says `sandbox` for the process of a sandboxed item, and gives the Julia flags of its profile. When an item of the run uses a profile other than `default`, the line names the profile of every worker. In a combined run, the line names the profile with its package, for example `profile default of B`. There, only the default profile of the first package has no name on the line. That package is the workspace root when the root has tests. When the run uses an environment directory, the line names the environment of the worker.

A `RUN` line gives the position of the item in the plan, its name and its location. A `DONE` line gives the outcome, the time, the fraction of the time that was compilation, and the most memory that the worker held.

### The progress line

On a terminal, the progress line stays at the bottom, and the run draws it again as it goes. In other output, the run prints it at these times:

- every `monitor_interval` seconds,
- after every 10 finished items, but no sooner than 5 seconds after the last progress line,
- when the run goes from setup to testing,
- when memory use crosses one of the high-memory marks, starting at 90%.

The progress line gives these values:

- the finished items and the selected items,
- the number of failed items,
- the busy workers and all workers,
- the memory of the processes of the run, and of the largest of them,
- the memory and CPU use of the machine,
- the stage of the run and its time.

## The block of a failed item

An item that did not pass gets a block with its results, right after its `DONE` line:

```text
🔴 w1 · 12:55:14 · DONE · 1/1 · "fails" · FAIL ·  0.0s (92% compile) · maxrss 0.3 GiB
┌ [1/1] FAIL "fails"
│ Test Failed at test/faults_test.jl:6
│   Expression: 1 == 2
│ [ No captured logs
└ @ test/faults_test.jl:5 on worker 1
```

The block holds the failed tests, the output of the item under `Captured logs`, and the path of the files that the item kept. The last line gives the location of the item and the worker. The run prints the block as one piece, so the output of another worker never lands inside it. Under `logs = :quiet`, the block has no output of the item.

## The closing block

```text
┌ [TEST] ran 6 test items in 2.1s on 2 workers, all passed
│ setup   · 1.1s · tree max  445M · child max  445M · coordinator
│ testing · 0.9s · tree max  1.0G · child max  460M · coordinator + 2 workers · 85% compile
│ (summed resident sizes over-count pages the processes share)
│ machine · 52.9G of 64.0G in use at peak
│ cpu · 8% of 18 threads for this run's processes, 24% for the whole machine (averages over the run)
└ run state: ~/.julia/runtests/runs/MyPackage-8db4f545/1790247276123456-96211.rundata
```

The first line gives the number of items, the time, the workers and the outcome. Then comes one line for each stage of the run, with its time and memory:

- `tree max` is the peak of the summed memory of every process that the run owns. These are the coordinator, the workers, and the processes that they start, for example Pkg or a process that a test starts.
- `child max` is the largest single process.
- The list after it says which processes the peak covers, for example `coordinator + 8 workers + 3 spawned`.

The `cpu` line gives two averages over the run, each a fraction of the CPU threads of the machine. The first is the use by the processes of the run. The second is the use by the whole machine. The difference shows how much CPU time other programs used. On Windows, only the use by the whole machine is given, because Windows keeps no total for the children of a process.

The block ends with these lines, when they apply:

- `coverage`, with the fraction of lines that ran,
- `run state`, the directory of the run, which holds the run state and the logs,
- in a combined run, one line for each package in place of `run state`, with the items of the package, those that did not pass, and the directory of its run,
- `copied to`, the directory that `RUNTESTS_ARTIFACT_DIR` named,
- the evidence that failed attempts kept,
- `run the failing items again`, with the command to type, when items failed.

After the block, `Test` prints its usual summary.

## The plan of a dry run

```text
┌ [TEST] dry run · v0.1.0 · julia 1.13.3 · 6 test items in 2 files · 2 workers · threads 2,1
│ startup: scan 0.0s
│ setups: `BasicSetup`
│ timeout: 1800s · retries: 0 · failfast: false · logs: issues · memory_threshold: 0.9
│ estimated work: w1 0.049s · w2 0.058s
└ order and workers: predicted from the recorded durations, an item without one counting as a typical one

  # · worker · test item    · at                   ·  est · tags       · why here      · details
  1 ·     w1 · "slow thing" · test/sub/b_test.jl:9 · 0.0s · slow       · [order] first · timeout 120s
  2 ·     w2 · "chain one"  · test/sub/b_test.jl:1 · 0.0s ·            ·               · chain `seq` 1/2
  3 ·     w2 · "chain two"  · test/sub/b_test.jl:5 · 0.0s ·            ·               · chain `seq` 2/2
  4 ·     w1 · "add works"  · test/a_test.jl:1     · 0.0s · fast
  5 ·     w2 · "uses setup" · test/a_test.jl:11    · 0.0s ·            ·               · setup `BasicSetup`
  6 ·     w1 · "mul works"  · test/a_test.jl:6     · 0.0s · fast, math
```

The table lists the items in the expected order of the run. Each row also gives the worker that is expected to run the item. The `estimated work` line gives the time that each worker is expected to be busy, from the recorded durations. Without recorded durations, the plan treats all items as equal, and the block has no `estimated work` line and no `est` column. The columns have these meanings:

| Column | Meaning |
|:-------|:--------|
| `#` | The position in the plan. |
| `worker` | The worker that is expected to run the item. |
| `test item` | The name, or [a unique prefix](@ref plan) of a long name. |
| `at` | The file and the line of the item. |
| `est` | The newest recorded duration, in seconds with one decimal. The column shows when earlier runs recorded durations. |
| `tags` | The tags of the item. |
| `why here` | The rule that placed the item, when the rule is not file order. |
| `details` | The keywords and setups of the item. |

## The output of chores

`Runtests.chores()` prints one block, with a line for each step. A step that takes longer than 3 seconds shows its duration on its line. [Maintain the suite](@ref chores) shows an example.

`Runtests.chores_mono()` prints one block for all packages of a monorepo, with paths from the workspace root. The block also shows the groups of workers. [Run the suites of a monorepo](@ref monorepos) describes it.
