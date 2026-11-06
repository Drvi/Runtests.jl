# [Maintain the suite](@id chores)

`Runtests.chores()` does the maintenance work of a suite. It does the work that needs no person, then reports what does need a person. Run it after you add a setup, edit a template or change `test/TestItems.toml`.

For all participating packages of a workspace in one pass, use [`Runtests.chores_mono()`](@ref monorepos).

```julia
Runtests.chores(dry_run = true)  # report what to change, and change nothing
Runtests.chores()                # do the changes, and report what remains
```

## What chores does

`chores` does these steps in order:

1. It converts the [setups](setups.md) into packages, and adds the packages that they started to import.
2. It expands the [templates](templates.md), and deletes the expansions whose templates are gone.
3. It reads the test items and `test/TestItems.toml`, and reports each problem that stops a run. Examples are a syntax error, a name that two items use and an incorrect value. Other examples are an `[order]` entry that names no item, an unknown profile, and a group with a tag that no item carries.
4. It deletes the run states that a run deletes when it prunes, by the same [retention rules](@ref retention), together with the directories of their runs. If other machines recorded run states of the project, it reports how many, from how many machines, and their size.
5. If the project keeps its run states in the default location, it deletes the run states of [deleted checkouts](@ref deleted-checkouts), with their directories.

`chores` never changes a test item, a configuration file or an expansion that a person edited. It never deletes a run state of another machine, for example of CI, or a run state that this version of Runtests cannot read.

A package without test files has nothing to read in step 3. An example is a fixture package in the `test/testfixtures/` of another package.

## What chores returns

`chores()` returns `true` when nothing remains. When a problem remains that a person must correct, it throws `Runtests.ChoresError`, after it did the rest of its work. Thus this line stops before any test runs on a suite that needs a person first:

```julia
Runtests.chores(); Runtests.runtests()
```

`chores(dry_run = true)` changes nothing. It returns `true` only when nothing needs work, neither by a person nor by `chores`. Reported maintenance problems return `false` without throwing `ChoresError`; invalid arguments or paths and unexpected I/O errors can still throw.

## Read other configuration files

A run can read another configuration file in place of `test/TestItems.toml`, with the `config` keyword. To make sure that such files are valid too, give them to `chores`:

```julia
Runtests.chores(config = "ci.toml")
Runtests.chores(config = ["ci.toml", "nightly.toml"])
```

`chores` reads each file in the same way as a run does, and also reads `test/TestItems.toml`. A relative path is relative to the current directory.

## Progress

`chores` prints a block with one line for each step. A step that takes longer than 3 seconds shows its duration. While `chores` expands templates, it prints the progress of each template. For example, it prints the time to load the packages that the template imports.

```text
┌ [TEST] chores
│ setups: 1 of 1 changed:
│   `ShapeData`: moved to ShapeData/src/ShapeData.jl · deps: none
│ templates: none
│ test items: 3 in 1 file, all valid
│ config: none
│ run states: 5 in ~/.julia/runtests/runs/Geometry-…, none to delete
│ checkouts that are gone: none with run states to delete
└ done: 1
```

The first argument finds the package as it does for `runtests`. Without it, `chores` uses the package of the active project.
