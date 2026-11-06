# [Measure coverage](@id coverage)

Runtests can count which lines of package source the tests run. It can merge worker counts into one `lcov.info` file, or Julia can write `.cov` files under `Pkg.test(coverage = true)`.

## Merge the counts into lcov.info

Set `coverage = true` in one of these ways:

- as a keyword: `Runtests.runtests(coverage = true)`,
- as an environment variable: `RUNTESTS_COVERAGE=true`,
- under `[run]` in `test/TestItems.toml`.

A keyword replaces the variable, and the variable replaces the file. The opening block of the run says which source set the value.

Each worker then counts which lines of `src/` and `ext/` of the package run. At the end, a one-package run merges the counts into `lcov.info` at the package root. A [combined run](@ref monorepos) includes each participating package's `src/` and `ext/` and writes one `lcov.info` at the workspace root. Codecov and Coveralls read this file.

The paths in `lcov.info` are relative to the root of the package's git checkout, because these services resolve paths from there. Thus a package in a subdirectory has its directory in front of its paths, for example `lib/Foo/src/Foo.jl`. Outside a git checkout, paths are relative to the package in a one-package run, and to the workspace root in a combined run.

Every line of a function that never ran counts as not covered. This also applies to a file that was never loaded. The closing block of the run gives the fraction of lines that ran:

```text
│ coverage: 33.3% of 6 lines in 2 files · lcov.info
```

## Limits

Coverage needs workers, so `workers = 0` with `coverage = true` is an error. A worker writes its counts when it exits, also after a timeout. A worker that stops without an exit loses its counts. Examples are a worker that the system killed and a worker that crashed. The closing block says how many workers lost their counts. On Windows, a worker that timed out is also stopped without an exit.

If the run cannot write the report, the closing block says so. The result of the run does not change.

## Use Pkg.test(coverage = true)

Under `Pkg.test(coverage = true)`, the workers take the coverage flags of Julia from the test process. They write `.cov` files next to the source files, as the test process does. `julia-actions/julia-processcoverage` merges these files. You do not have to set anything. `julia-actions/julia-runtest` uses this way by default.

## Upload lcov.info from CI

To upload the file that Runtests merges, set `RUNTESTS_COVERAGE` in the test step:

```yaml
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_COVERAGE: true
- uses: codecov/codecov-action@v5
  with:
    files: lcov.info
```
