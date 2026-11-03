using Documenter
using Runtests
using Test

# Every public name has its docstring on the API page. `checkdocs` cannot tell: the
# names are defined in `Runtests.Private`, whose own exports are internal, as are
# those of `RuntestsWorkers`, and ignoring those modules hides the docstrings from
# `@docs` too. The names of `Test` are re-exported, documented by `Test`.
api = read(joinpath(@__DIR__, "src", "reference", "api.md"), String)
undocumented = [n for n in names(Runtests) if !(n in names(Test)) && !occursin(Regex("^\\Q$n\\E\$", "m"), api)]
isempty(undocumented) || error("public names missing from reference/api.md: ", join(undocumented, ", "))

makedocs(;
    sitename = "Runtests.jl",
    modules = [Runtests],
    authors = "Drvi",
    format = Documenter.HTML(;
        # Local builds open from the file system, where `page/` does not resolve to
        # `page/index.html`.
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://drvi.github.io/Runtests.jl",
        edit_link = "main",
    ),
    # The check above stands in for this one.
    checkdocs = :none,
    pages = [
        "Home" => "index.md",
        "Get started" => "tutorial.md",
        "Guides" => [
            "guide/running.md",
            "guide/writing.md",
            "guide/setups.md",
            "guide/templates.md",
            "guide/chores.md",
            "guide/configuration.md",
            "guide/profiles.md",
            "guide/failures.md",
            "guide/repl.md",
            "guide/ci.md",
            "guide/coverage.md",
            "guide/measuring.md",
            "guide/editors.md",
            "guide/porting.md",
        ],
        "Explanation" => [
            "explanation/run.md",
            "explanation/history.md",
        ],
        "Reference" => [
            "reference/syntax.md",
            "reference/configuration.md",
            "reference/output.md",
            "reference/files.md",
            "reference/editor-protocol.md",
            "reference/api.md",
        ],
        "Glossary" => "glossary.md",
    ],
)

deploydocs(; repo = "github.com/Drvi/Runtests.jl.git", devbranch = "main")
