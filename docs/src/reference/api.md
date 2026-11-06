# [API](@id api)

```@meta
CurrentModule = Runtests
```

This page holds the docstrings of the public API of Runtests. `using Runtests` brings the exported names into scope: `@testitem`, `@testtemplate`, `runtests`, `runtestsf`, `chores`, `runtests_mono` and `chores_mono`. It also exports `Test` and the macros of `Test`, for example `@test` and `@testset`. Reach the other public names with the `Runtests.` prefix, for example `Runtests.on_failure`.

The heading of each docstring names the module that defines the name, for example `Runtests.Private.runtests`. `Runtests.Private` and `Runtests.RuntestsWorkers` are internal modules. Always use the public name, for example `Runtests.runtests`.

```@docs
Runtests
```

## Run tests

```@docs
runtests
runtestsf
runtests_mono
RunTestSet
ItemEvent
```

## Declare tests

```@docs
@testitem
@testtemplate
```

## Maintain the suite

```@docs
chores
chores_mono
setups_to_packages
```

## Inside a test item

`current_testitem()` returns a `TestItemInfo` with the fields `name`, `file`, `line`, `attempt` and `profile`.

```@docs
current_testitem
on_failure
artifacts_dir
RuntestsWorkers.TestItemInfo
```

## At the REPL

```@docs
activate
activate_mono
deactivate
is_activated
debug
```

## Run states

```@docs
read_run_state
```

## Editors

```@docs
serve
serve_mono
```

## Exceptions

```@docs
ScanFailure
NoTestsError
ConfigError
ChoresError
```
