# [Output](@id output)

This page describes the output of a run, in five parts. These are the opening block, the lines of the run, the block of a failed item, the closing block and the dry-run plan. The examples come from a small suite. Times and memory depend on the suite and on the machine.

## The opening block

```text
┌ [TEST] v0.1.0 · julia 1.13.0 · 6 test items in 2 files · seed 0x0c15831ed3676a15 · 2 workers · threads 2,1
│ env: /var/folders/…/jl_vWMrc1/Project.toml
└ startup: files 0.0s · plan 0.1s · setup 1.4s
```

The first line gives the versions of Runtests and Julia, and the number of selected items and files. It also gives the seed, the number of workers and their threads. It names these values too, when they apply:

- the selection, for example `matching tags = [:fast]`,
- the group and what selected it,
- the Julia flags of the workers that a plain `julia` does not have, for example `--check-bounds=yes -O1`,
- the environment variables that set configuration values,
- the source of the `coverage` value.

The `env` line is the path of the test environment. The `startup` line gives the time to read the files, to make the plan and to set up the environment.

## The lines of the run

Workers, items and the run itself each print lines of one shape:

```text
⚪ w0 · 12:54:36 · INFO · 0/6 · 0 failed · 0/2 workers · tree mem 845M (max 845M) · child max 448M · mem 89% · cpu 10.6/18 · testing 1s
⚫ w1 · 12:54:37 · UP   · pid 96279 · threads 2,1
🔵 w1 · 12:54:37 · RUN  · 1/6 · "slow thing" · at test/sub/b_test.jl:9
🟢 w1 · 12:54:37 · DONE · 1/6 · "slow thing" · PASS ·  0.0s (93% compile) · maxrss 0.3 GiB
⚫ w1 · 12:54:39 · EXIT · pid 96279 · 3 items · 2.1s
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

An `UP` line gives the process ID and the threads of the worker. It also says `sandbox` for the process of a sandboxed item, and gives the Julia flags of its profile. When the run uses more than one profile, it names the profile. When the run uses an environment directory, it names the environment of the worker.

A `RUN` line gives the position of the item in the plan, its name and its location. A `DONE` line gives the outcome, the time, the fraction of the time that was compilation, and the most memory that the worker held.

### The progress line

On a terminal, the progress line stays at the bottom, and the run draws it again as it goes. In other output, the run prints it at these times:

- every `monitor_interval` seconds,
- after every 10 finished items, but no sooner than 5 seconds after the last progress line,
- when the run goes from setup to testing,
- when the memory of the machine goes over 90%.

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
│ No captured logs
└ @ test/faults_test.jl:5 on worker 1
```

The block holds the failed tests, the output of the item under `Captured logs`, and the path of the files that the item kept. The last line gives the location of the item and the worker. The run prints the block as one piece, so the output of another worker never lands inside it. Under `logs = :quiet`, the block has no output of the item.

## The closing block

```text
┌ [TEST] ran 6 test items in 3.3s on 2 workers, all passed
│ setup   · 1.3s · tree max  422M · child max  422M · coordinator
│ testing · 1.8s · tree max  1.0G · child max  452M · coordinator + 2 workers · 87% compile
│ (summed resident sizes over-count pages the processes share)
│ machine · 57.7G of 64.0G in use at peak
│ cpu · 9% of 18 threads for this run's processes, 14% for the whole machine (averages over the run)
└ run state: ~/.julia/runtests/runs/MyPackage-8db4f545/1790247276123456-96211.runstate
```

The first line gives the number of items, the time, the workers and the outcome. Then comes one line for each stage of the run, with its time and memory:

- `tree max` is the peak of the summed memory of every process that the run owns. These are the coordinator, the workers, and the processes that they start, for example Pkg or a process that a test starts.
- `child max` is the largest single process.
- The list after it says which processes the peak covers, for example `coordinator + 8 workers + 3 spawned`.

The `cpu` line gives two averages over the run, each a fraction of the CPU threads of the machine. The first is the use by the processes of the run. The second is the use by the whole machine. The difference shows how much CPU time other programs used. On Windows, only the use by the whole machine is given, because Windows keeps no total for the children of a process.

The block ends with these lines, when they apply:

- `coverage`, with the fraction of lines that ran,
- `run state`, the path of the run state,
- `logs`, the directory of the logs, when an item printed something,
- `copied to`, the directory that `RUNTESTS_ARTIFACT_DIR` named,
- the evidence that failed attempts kept,
- `run the failing items again`, with the command to type, when items failed.

After the block, `Test` prints its usual summary.

## The plan of a dry run

```text
┌ [TEST] dry run · v0.1.0 · julia 1.13.0 · 6 test items in 2 files · 2 workers · threads 2,1
│ startup: files 0.0s · plan 0.0s
│ setups: `BasicSetup`
│ timeout: 1800s · retries: 0 · failfast: false · logs: issues · memory_threshold: 0.9
└ order and workers: predicted as if every item took as long, since no durations are recorded yet

  # · worker · test item    · at                   · tags       · why here      · details
  1 ·     w1 · "slow thing" · test/sub/b_test.jl:9 · slow       · [order] first · timeout 120s
  2 ·     w2 · "chain one"  · test/sub/b_test.jl:1 ·            ·               · chain `seq` 1/2
  3 ·     w2 · "chain two"  · test/sub/b_test.jl:5 ·            ·               · chain `seq` 2/2
  4 ·     w1 · "add works"  · test/a_test.jl:1     · fast
  5 ·     w2 · "uses setup" · test/a_test.jl:11    ·            ·               · setup `BasicSetup`
  6 ·     w1 · "mul works"  · test/a_test.jl:6     · fast, math
```

The table lists the items in the expected order of the run. Each row also gives the worker that is expected to run the item. The columns have these meanings:

| Column | Meaning |
|:-------|:--------|
| `#` | The position in the plan. |
| `worker` | The worker that is expected to run the item. |
| `test item` | The name, or [a unique prefix](@ref plan) of a long name. |
| `at` | The file and the line of the item. |
| `est` | The newest recorded duration. The column shows when earlier runs recorded durations. |
| `tags` | The tags of the item. |
| `why here` | The rule that placed the item, when the rule is not file order. |
| `details` | The keywords and setups of the item. |

## The output of chores

`Runtests.chores()` prints one block, with a line for each step. A step that takes longer than 3 seconds shows its duration on its line. [Maintain the suite](@ref chores) shows an example.
