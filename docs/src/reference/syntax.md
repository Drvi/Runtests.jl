# [Syntax](@id syntax)

This page gives the exact syntax of test files, test items, test templates and tag expressions. It also tells [where each piece of code runs](@ref where-code-runs). [Write test items](@ref writing) and [Generate test items from a template](@ref templates) explain how to use them.

## File names

Runtests reads the files under `test/`. Each Julia file there must match one of these rules:

| Path | Meaning |
|:-----|:--------|
| `test/runtests.jl` | The entry point that `Pkg.test` runs. |
| `test/**/*_test.jl`, `test/**/*_tests.jl` | A test file. It holds `@testitem` declarations only. |
| `test/testsetups/Name.jl`, `test/testsetups/Name/src/Name.jl` | A test setup: the module `Name`. |
| `test/testtemplates/*_test_template.jl`, `test/testtemplates/*_tests_template.jl` | A test template. It holds `@testtemplate` declarations only. |
| `test/testfixtures/**` | Input for the tests. Runtests never reads it as part of the suite. |
| `test/**/` with a `Project.toml` or `JuliaProject.toml` | An environment directory. Its test files run in that environment. |

A hidden file or directory, whose name starts with `.`, is not part of the suite. A Julia file that matches no rule stops the run.

Every nested `Project.toml` or `JuliaProject.toml` that discovery encounters makes its directory an [environment directory](@ref environments). The innermost one that holds a test file is the environment of its items. The root `test/` project is the test environment. Setup packages under `test/testsetups/`, projects under `test/testtemplates/` and fixture projects under `test/testfixtures/` are not environment directories. Only the suite-root `test/testfixtures/` is reserved: a deeper directory with that name is an ordinary directory.

The expansion of `test/testtemplates/x_tests_template.jl` is `test/x_tests.jl`.

## @testitem

```julia
@testitem "name" keyword=value ... begin
    body
end
```

The name is a string literal that is not blank. It must be unique across the suite. The keywords come between the name and `begin`, in any order.

### [Keywords](@id testitem-keywords)

| Keyword | Value | Default | Meaning |
|:--------|:------|:--------|:--------|
| `tags` | A vector of symbols, for example `[:fast, :math]`. | none | The tags that a run can select by. |
| `timeout` | A positive number of seconds. | The `timeout` of the run. | The time that each attempt can take. |
| `retries` | An integer from 0 to 126. | The `retries` of the run. | The number of more attempts after a failure. A chain retries from its first item. |
| `skip` | `true`, `false`, or an expression that gives a `Bool`. | `false` | Skip the item. The worker evaluates the expression before the body. |
| `failfast` | `true` or `false`. | The `item_failfast` of the run. | Stop the item at its first failed test. |
| `chain` | A symbol, for example `:db`. | none | The items of a chain run in sequence, on one worker. |
| `sandbox` | `true` or `false`. | `false` | `true` runs the item alone in a new process. |
| `profile` | The name of a profile as a symbol, for example `:bounds`. | `:default` | The profile of the workers that run the item. |

Each value except the value of `skip` must be a literal. Arithmetic on numeric literals is a literal too, for example `timeout = 5*60`. `sandbox = true` and `chain` cannot go together. `sandbox = true` and `profile` combine. All items of one chain must use the same profile and be in the same environment. `sandbox = :name` is an error that tells you to write `profile = :name`.

The `skip` expression runs on the worker, in a module of its own, with `Test` and the package in scope, before the imports of the body. An exception in it, or a value that is not a `Bool`, is an error of the item.

### The body

The body runs at the top level of a new module, with the soft scope of the REPL. `Test` and the package under test are in scope. The variables of the body are untyped globals.

## @testtemplate

```julia
@testtemplate "name with $x" keyword=value ... for x in xs, y in ys
    body with $x
end
```

A template makes one test item for each iteration of the loop. With several loop variables, the first one changes slowest. The loop runs in a module that holds `Test`, the package under test, and each package that the body imports, by its module name only.

### Interpolation

| Location | Form | Meaning |
|:---------|:-----|:--------|
| Name | `"case $n"` | The value of the iteration goes into the literal name. |
| Body or keywords | `$n` | The value of the loop variable goes in as Julia code. |
| Keywords | `$(expression)` | The expansion evaluates the expression once for each iteration, in the scope of the loop, and writes its value. |
| Body | `$` before anything else than a loop variable | The expansion leaves it as it is, for a macro of the body. |
| Quoted expressions | any `$` | The expansion leaves it as it is. |

An inserted value is written with `repr`, as the module of the item sees it with the imports of the body. It must evaluate back to an equal value there. A loop variable without `$` in the body is an error, unless the body binds it, as `x = $x` does. Inside a string in the body, write `"$($x)"` to insert the value.

`@testtemplate` evaluated anywhere else than in a template that `chores` expands throws an error.

## [Tag expressions](@id tag-expressions)

The `tags` keyword of `runtests` and the values of `[groups]` take a tag expression as a string:

```text
expression  = alternative { "||" alternative }
alternative = term { "&&" term }
term        = [ "!" ] tag
tag         = one or more characters that are not white space, "!", "&", "|", ":", "(" or ")"
```

`!` negates one tag. `&&` binds tighter than `||`. Parentheses are not part of the syntax. White space around the operators has no effect. Examples:

| Expression | Selects |
|:-----------|:--------|
| `"fast"` | The items with the tag `fast`. |
| `"!slow"` | The items without the tag `slow`. |
| `"fast && !slow"` | The items with `fast` and without `slow`. |
| `"juliac \|\| serializer"` | The items with `juliac`, or with `serializer`, or with both. |
| `"a && b \|\| c"` | The items with `a` and `b`, or with `c`. |

The `tags` keyword also takes a symbol, which selects the items with that tag. A vector of symbols selects the items with all of its tags. An expression that names a tag that no item of the suite carries is an error.

## [Where code runs](@id where-code-runs)

The process that calls `runtests` or `chores` parses test files and templates, and does not evaluate them. Their code, and the code of a profile, runs in these places:

| Code | Process | When | Module | Names in scope |
|:-----|:--------|:-----|:-------|:---------------|
| `init` of a profile | Each worker of the profile, and under `workers = 0` the process that calls `runtests` for the default profile | Once, before the first item of the process | `Main` of the process | The names in `Main` |
| `skip` of an item | The process of the item | Before the body | A new module | `Test` and the package |
| Body of an item | The process of the item | After `skip` | A new module, with the soft scope of the REPL | `Test`, the package and the imports of the body |
| `test_end` of a profile | The process of the item | After each attempt that was not skipped | A new module | `Test` and the package |
| Producer of `Runtests.on_failure` | The process of the item | After the verdict of an attempt that failed | The module of the item | The names of the item, with their values at that time |
| Loop of a template, and each `$(...)` in its keywords | A process that `chores` starts, with the test environment | Once for each iteration | A module named `Template` | `Test`, the package and the packages that the body imports, by module name only |

Each piece of code can import any package of the environment of its process. On a worker, that is the test environment, or the environment directory of the item over the test environment. Thus `init` and `test_end` can import every test dependency. An `init` that imports a package of one environment directory fails on the workers of the other environments of its profile.

Names do not pass from one piece of code to another, but the process stays the same. A package that one piece loads stays loaded for the next, and a method that one piece adds to a function stays added. [Items on one worker](@ref items-on-one-worker) describes this.

Each new module is a module in `Main`, but it does not see the names in `Main`. Thus an item does not see what `init` defines or imports. An item can reach a value that `init` defines as `Main.name`. An `init` such as `using Plots` loads the package before the first item, but does not put it in the scope of the items. An item that uses the package must import it.

`skip`, the body and `test_end` do not share names. The body does not see what `skip` defines, and `test_end` does not see the variables of the body. `skip` and the body both start from the seed of the item, so the first `rand()` gives the same value in each. What `skip` prints goes to the log of the item.

### The working directory

The code of an item runs in the root of its package: its `skip`, its body, the `test_end` of its profile and its producers. This is true on a worker and in the process that calls `runtests` under `workers = 0`. It is also true under `Pkg.test`, which starts the tests in `test/`, and at the REPL. In a combined run, each item runs in the root of its own package. The run changes into that directory before the item, and changes back after it. Thus a change of the working directory in one item does not reach the next item.

`init` runs in the root of the package, or in the workspace root for a [shared profile](@ref shared-profiles). Under `workers = 0`, the `init` of the default profile runs once in `Main` of the process that calls `runtests`, in that directory too, and the run warns about it.

The loop of a template runs in the current directory of the process that calls `chores`. To read a file, build its path from `@__DIR__`. In the body of an item and in a template, `@__DIR__` is the directory of the file that holds the code, in every process.
