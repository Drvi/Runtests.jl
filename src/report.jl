# Human-facing output for a plan. `--dry-run` prints this and stops.

function print_plan(io::IO, p::Plan; show_excluded::Vector{String} = String[])
    order = run_order(p)
    print(io, plan_block(p, order))
    print_plan_table(io, p, order)
    if !isempty(show_excluded)
        println(io)
        println(io, "excluded: ", length(show_excluded), " items")
        for line in show_excluded
            println(io, "  ", line)
        end
    end
    return nothing
end

# What the plan is for and what it was made from, in the bracket a run's header is
# drawn in: the table below it is the plan.
function plan_block(p::Plan, order)
    cfg = p.cfg
    head = sprint() do io
        print(io, "dry run · ")
        print_work(io, p, single_process(p) ? 0 : nslots(p))
    end
    body = sprint() do io
        print_selection(io, p)
        print_packages(io, p)
        print_startup(io, p.startup)
        isempty(p.setups) || println(io, "setups: ", join(("`$s`" for s in p.setups), ", "))
        println(io, "timeout: ", cfg.timeout_s, "s · retries: ", cfg.retries, " · failfast: ", cfg.failfast,
                " · logs: ", cfg.logs, " · memory_threshold: ", cfg.memory_threshold)
        print_profiles(io, p)
        print_env_settings(io, p.cfg)
        print_coverage_setting(io, p.cfg)
        estimated = any(>(0), p.items.est_s)
        if !single_process(p)
            estimated && println(io, "estimated work: ",
                                 join(("w$s $(est_text(w))" for (s, w) in enumerate(order.work)), " · "))
            println(io, "order and workers: predicted ",
                    estimated ? "from the recorded durations, an item without one counting as a typical one" :
                        "as if every item took as long, since no durations are recorded yet")
        end
    end
    return bracket(body, "[TEST]", head, "", :default)
end

# The opening words of a run's header and of a dry run's: which Runtests and Julia, how
# much work, and on how many processes.
function print_work(io::IO, p::Plan, nworkers::Integer; seed::Union{Nothing, UInt64} = nothing)
    print(io, "v", pkgversion(@__MODULE__), " · julia ", VERSION, " · ", plural(nitems(p), "test item"),
          " in ", plural(length(p.files), "file"))
    # The commit, so a CI log says what to check out to reproduce this run.
    rev = project_revision(p.root)
    isempty(rev) || print(io, " · rev ", first(rev, 10))
    seed === nothing || print(io, " · seed ", seed_text(seed))
    own = count(i -> haskey(item_cfg(p, i).item_seeds, p.items.name[i]), 1:nitems(p))
    own == 0 || print(io, " · ", plural(own, "item"), " with ", own == 1 ? "its" : "their", " own seed")
    p.cfg.workers == 0 ? print(io, " · in this process") :
        print(io, " · ", plural(nworkers, "worker"), " · threads ", p.profiles[1].threads)
    # What a plain `julia` would not do, for whoever compares this run with another.
    flags = nondefault_flags(run_code_flags(p.cfg))
    isempty(flags) || print(io, " · ", join(flags, " "))
    return nothing
end

# What selected the items of the run, a line of its own in the bracket of a header: a
# group, with its tags and what asked for it, can be long.
print_selection(io::IO, p::Plan) = isempty(p.selection) || println(io, "selection: ", p.selection)

# What a profile sets, each said briefly; `threads` is what a profile that sets none
# runs with, which is not said. A preferences file is named from `root`. With `detail`,
# for profiles of one name that differ: the file of each expression, and the packages
# the run precompiles for its workers.
function profile_parts(prof::Profile, threads::AbstractString, root::AbstractString = ""; detail::Bool = false)
    parts = String[]
    from(path) = isempty(root) ? path : relpath_or_path(path, root)
    isempty(prof.julia_args) || push!(parts, join(prof.julia_args, " "))
    (isempty(prof.threads) || prof.threads == threads) || push!(parts, string("threads ", prof.threads))
    isempty(prof.env) || push!(parts, join(("$k=$v" for (k, v) in prof.env), " "))
    isempty(prof.preferences) || push!(parts, string("preferences ", from(prof.preferences)))
    for (ex, what) in ((prof.init, "init expression"), (prof.test_end, "test end expression"))
        isempty(ex.args) && continue
        at = findfirst(a -> a isa LineNumberNode && a.file !== nothing, ex.args)
        push!(parts, detail && at !== nothing ? string(what, " of ", from(string(ex.args[at].file))) : what)
    end
    detail && prof.precompile !== nothing &&
        push!(parts, isempty(prof.precompile) ? "precompiles nothing" : string("precompiles ", join(prof.precompile, ", ")))
    return parts
end

# What tells two profiles' settings apart, as their workers get them: an expression by
# its code, wherever it was written.
profile_settings(prof::Profile) =
    (prof.julia_args, prof.threads, prof.env, prof.preferences, Base.remove_linenums!(deepcopy(prof.init)),
     Base.remove_linenums!(deepcopy(prof.test_end)), prof.precompile)

# Only profiles that actually change something are worth a line, one each however
# many environments they run in, and the environment directories the items run in one
# more. In a run of several packages, a name whose settings differ between packages
# has a line for each settings, with the packages that have them, in enough detail to
# tell them apart.
function print_profiles(io::IO, p::Plan)
    names = Symbol[]
    groups = Dict{Symbol, Vector{Tuple{Any, Int, Vector{String}}}}()   # (settings, a profile, packages)
    for (j, prof) in pairs(p.profiles)
        haskey(groups, prof.name) || (push!(names, prof.name); groups[prof.name] = [])
        key = profile_settings(prof)
        package = p.packages.name[p.profile_package[j]]
        same = groups[prof.name]
        k = findfirst(g -> isequal(g[1], key), same)
        k === nothing ? push!(same, (key, j, [package])) : (package in same[k][3] || push!(same[k][3], package))
    end
    threads = p.profiles[1].threads
    for name in names
        same = groups[name]
        if length(same) == 1
            parts = profile_parts(p.profiles[only(same)[2]], threads, p.root)
            isempty(parts) || println(io, "profile `", name, "`: ", join(parts, " · "))
            continue
        end
        for (_, j, packages) in same
            parts = profile_parts(p.profiles[j], threads, p.root; detail = true)
            println(io, "profile `", name, "` of ", join(packages, ", "), ": ",
                    isempty(parts) ? "nothing of its own" : join(parts, " · "))
        end
    end
    envs = unique!(String[string(relpath_or_path(prof.environment, p.root), skips_environment(p, j) ? " (skipped)" : "")
                          for (j, prof) in pairs(p.profiles) if !isempty(prof.environment)])
    isempty(envs) || println(io, length(envs) == 1 ? "env dir: " : "env dirs: ", join(envs, ", "))
    return nothing
end

"""
    run_order(p) -> (; items, work)

The order the run is expected to start the items in, and where: its own dispatch
(`claim!`) played out with each unit taking as long as the recorded runs say, and a
unit nothing is recorded for counting as a typical one. A worker that moves to
another profile's items first pays what the recorded runs say a fresh worker costs.
`items` holds `(start, worker, item)` in that order; `work` is each worker's
estimated busy seconds, without what it waits for a gate. A run without workers takes the units in plan order.
"""
function run_order(p::Plan)
    typical = typical_estimate(p.items.est_s)
    est = [e > 0 ? e : typical for e in p.items.est_s]
    items = Tuple{Float64, Int, ItemIdx}[]
    if single_process(p)
        t = 0.0
        for i in ItemIdx(1):ItemIdx(nitems(p))
            push!(items, (t, 1, i))
            t += est[i]
        end
        return (; items, work = [t])
    end
    q = Queues(p)
    free = zeros(nslots(p))
    waited = zeros(nslots(p))   # what of `free` a worker spent waiting for a gate, not working
    done = falses(nslots(p))
    gated = Tuple{Float64, ItemIdx}[]   # the items of gates handed out, and when each ends
    while !all(done)
        # The next worker to ask is the first free, and the lowest numbered of those.
        s = argmin(k -> (done[k], free[k], k), 1:nslots(p))
        # What ended by then lets its gate run another.
        for (t, item) in gated
            t <= free[s] && item_ended!(q, item)
        end
        filter!(((t, _),) -> t > free[s], gated)
        claim = @lock q.lock claim_now!(q, s)
        if claim.kind === :wait
            # It waits for the first of the gates' items to end.
            isempty(gated) && error("Runtests internal error: a worker waits for a gate that runs nothing")
            t = minimum(first, gated)
            waited[s] += t - free[s]
            free[s] = t
            continue
        end
        claim.kind === :done && (done[s] = true; continue)
        claim.kind === :rebind && (free[s] += cold_cost(q, claim.pool); continue)
        push!(items, (free[s], s, claim.item))
        free[s] += est[claim.item]
        q.gate[claim.item] == 0 || push!(gated, (free[s], claim.item))
    end
    return (; items = sort!(items; by = x -> (x[1], x[2])), work = free .- waited)
end

# An estimate as the dry run gives it: to a tenth of a second like every other
# duration, but a sub-second one to two figures, which a tenth would round to 0.0s.
est_text(s::Real) = s < 1 ? string(round(s; sigdigits = 2), "s") : fmt_seconds(s)

# Seconds with one decimal at any size, so that a column of them lines up on the point
# and reads at a glance. A time no run takes, which only a damaged run state holds, is
# said as it is.
function tenths_text(s::Real)
    0 <= s < 1.0e12 || return string(s, "s")
    tenths = round(Int, 10s)
    return string(div(tenths, 10), ".", rem(tenths, 10), "s")
end

"""
    why_text(p, u, work = gate_work(p)) -> String

Why unit `u` is handed out where it is, for the dry run: empty for a unit in its
worker's stretch, where file order put it. `work` is each gate's, which a caller
with many rows sums once.
"""
function why_text(p::Plan, i::Integer, work::Vector{Float64} = gate_work(p))
    it = p.items
    why = it.why[i]
    throttle = it.throttle[i]
    why === PINNED_FIRST && return "[order] first"
    why === PINNED_LAST && return "[order] last"
    why === SANDBOXED && return "sandbox"
    if why === LONG
        g = it.gate[i]
        # A gate's item is as long as its own estimate or its gate's work over its
        # limit, whichever is longer (`order_pool!`).
        floor = g == 0 ? 0.0 : work[g] / p.gate_limit[g]
        it.est_s[i] < floor && return string("long: throttle `", throttle, "` est ", est_text(floor), ", ",
                                             p.gate_limit[g], " at a time")
        return string("long: est ", est_text(it.est_s[i]),
                      throttle === NO_THROTTLE ? "" : string(" (throttle: `", throttle, "`)"))
    end
    why === RECENT || return ""
    ago = it.failed_ago[i]
    how = it.cancelled[i] ? "cancelled" : "failed"
    failed = ago < 0 ? "" : ago == 0 ? "$how in the last run" : string(how, " ", ago + 1, " runs ago")
    changed = !it.changed[i] ? "" : it.changed_new[i] ? "new" : "edited since its last run"
    return join(filter(!isempty, [failed, changed]), ", ")
end

# Each gate's recorded work: its items' estimates, summed.
function gate_work(p::Plan)
    work = zeros(length(p.gate_limit))
    for (i, g) in pairs(p.items.gate)
        g == 0 || (work[g] += p.items.est_s[i])
    end
    return work
end

# What an item row says about the item itself: the keywords it was declared with,
# its throttle's limit, and the setups it loads.
function details_text(p::Plan, i::Integer)
    it = p.items
    parts = String[]
    g = it.gate[i]
    g == 0 || push!(parts, string("throttle `", it.throttle[i], "`, ", p.gate_limit[g], " at a time"))
    # A sandbox is the reason it goes early, unless something else put it there.
    it.exclusive[i] && it.why[i] !== SANDBOXED && push!(parts, "sandbox")
    prof = p.profiles[it.profile[i]]
    prof.name === DEFAULT_PROFILE || push!(parts, string("profile `", prof.name, "`"))
    it.timeout_s[i] == USE_RUN_DEFAULT || push!(parts, string("timeout ", it.timeout_s[i], "s"))
    it.retries[i] == USE_RUN_DEFAULT || push!(parts, string("retries ", it.retries[i]))
    setups = setups_of(it, i)
    isempty(setups) || push!(parts, string(length(setups) == 1 ? "setup " : "setups ",
                                           join(("`$s`" for s in setups), ", ")))
    return join(parts, ", ")
end

"""
    shown_names(names, width; among = names) -> Vector{String}

Each of `names` as a column `width` wide shows it. A name that fits is quoted as it
is. One that does not becomes `r"^…"`: a prefix of it as long as fits, and never
shorter than the shortest prefix no other name in `among` starts with, so that
passed to `name=` it picks out that item and no other. `among` is every name in the
suite, since a filter can leave out the item whose name a prefix would also match.
When even that prefix does not fit, the name overruns the column with it; when no
prefix is its own (the name begins another), it overruns the column whole. With any
name shortened, every name gets a column in front of its opening quote, `r` or a
space, so the quotes line up.
"""
function shown_names(names::Vector{String}, width::Integer; among::Vector{String} = names)
    quoted = [repr(n) for n in names]
    all(q -> textwidth(q) <= width, quoted) && return quoted
    # In sorted order, a name shares its longest prefix with one of its neighbours.
    pool = sort!(unique!(vcat(among, names)))
    common(a, b) = (k = 0; for (x, y) in zip(a, b); x == y || break; k += 1; end; k)
    need = map(names) do n
        j = searchsortedfirst(pool, n)
        before = j > 1 ? common(n, pool[j - 1]) : 0
        after = j < length(pool) ? common(n, pool[j + 1]) : 0
        max(before, after) + 1
    end
    shortened = map(eachindex(names)) do i
        n = names[i]
        textwidth(quoted[i]) <= width && return nothing
        need[i] >= length(n) && return nothing   # no prefix of its own, or none shorter
        # The longest prefix whose `"^…"` fits, but no shorter than `need`.
        k = need[i]
        shown = regex_prefix(n, k)
        shown === nothing && return nothing   # a character no regex here can show: the name stays whole
        while k + 1 < length(n)
            longer = regex_prefix(n, k + 1)
            (longer !== nothing && textwidth(longer) - 1 <= width) || break
            k += 1
            shown = longer
        end
        return shown
    end
    any(!isnothing, shortened) || return quoted
    return [s === nothing ? " " * q : s for (s, q) in zip(shortened, quoted)]
end

"""
    item_names(p, width) -> (names, column)

Every item's name as the run writes it in the name column, and the column's width:
one too long for `width` is shortened as [`shown_names`](@ref) does, unless the run
asked for `full_names`.
"""
function item_names(p::Plan, width::Integer)
    p.cfg.full_names && return [repr(n) for n in p.items.name], width
    names = shown_names(p.items.name, width; among = p.suite_names)
    # With any name shortened, every name has a column in front of its opening quote.
    return names, width + any(n -> !startswith(n, '"'), names)
end

# The characters PCRE reads as other than themselves outside a character class.
const REGEX_SPECIAL = "\\^\$.|?*+()[]{}"

# `r"^…"` for the first `k` characters of `name`, written as Julia source for a
# regular expression that matches those characters literally: as they are when none
# is special, after `\Q` when one is, which PCRE reads every character after as
# itself until `\E`. Quoted only when needed, because `\Q` takes two of the column's
# characters. `nothing` when one of them does not print: inside `\Q` nothing is an
# escape, and the line could not show it as it is.
function regex_prefix(name::AbstractString, k::Integer)
    prefix = first(name, k)
    all(isprint, prefix) || return nothing
    pattern = if any(in(REGEX_SPECIAL), prefix)
        # A `\E` in the name would end the quoting: it closes it, is written
        # escaped, and opens it again.
        string("^\\Q", replace(prefix, "\\E" => "\\E\\\\E\\Q"))
    else
        string("^", prefix)
    end
    # A raw string halves the backslashes before a quote, its closing one included.
    return string("r\"", Base.escape_raw_string(pattern), "\"")
end

"""
    print_plan_table(io, p, order)

Every test item, a row each, in the order the run is expected to start them (see
[`run_order`](@ref)): the worker expected to run it, where it is, its tags, why it
goes where it does when that is not file order, and what it was declared with.
Columns are separated as the fields of the run's lines are, and each is as wide as
the widest thing in it; a column nothing fills is left out. The names are written
as the run's lines write them (see [`item_names`](@ref)).
"""
function print_plan_table(io::IO, p::Plan, order)
    it = p.items
    n = nitems(p)
    solo = single_process(p)
    rows = [i for (_, _, i) in order.items]
    workers = [string("w", s) for (_, s, _) in order.items]
    shown, column = item_names(p, run_name_width(p))
    names = [shown[i] for i in rows]
    locations = [string(p.relfiles[it.fileidx[i]], ":", it.line[i]) for i in rows]
    ests = [it.est_s[i] > 0 ? tenths_text(it.est_s[i]) : "" for i in rows]
    tags = [join(tags_of(it, i), ", ") for i in rows]
    work = gate_work(p)
    whys = [why_text(p, i, work) for i in rows]
    details = [details_text(p, i) for i in rows]
    columns = Tuple{String, Vector{String}}[]
    push!(columns, ("#", [string(i) for i in 1:n]))
    solo || push!(columns, ("worker", workers))
    # In a run of several packages, the package whose suite holds the item.
    is_combined(p) && push!(columns, ("package", [p.packages.name[it.package[i]] for i in rows]))
    push!(columns, ("test item", names))
    push!(columns, ("at", locations))
    any(!isempty, ests) && push!(columns, ("est", ests))
    any(!isempty, tags) && push!(columns, ("tags", tags))
    any(!isempty, whys) && push!(columns, ("why here", whys))
    any(!isempty, details) && push!(columns, ("details", details))
    # A name wider than the column overruns it rather than widening it for all.
    widths = map(columns) do (title, cells)
        title == "test item" ? max(length(title), column) :
            max(length(title), maximum(textwidth, cells; init = 0))
    end
    println(io)
    for r in 0:n
        print(io, GUTTER)
        # A row ends at its last filled column: the empty ones after it are left
        # off, separators and all, while an empty one before it keeps its place.
        cells = [r == 0 ? title : col[r] for (title, col) in columns]
        last_ = something(findlast(!isempty, cells), 1)
        for c in 1:last_
            c == 1 || print(io, FIELD)
            # The number, the worker and the estimate are right-aligned, the rest
            # left, and the last column is not padded.
            text = columns[c][1] in ("#", "worker", "est") ? lpad(cells[c], widths[c]) :
                c == last_ ? cells[c] : rpad(cells[c], widths[c])
            r == 0 ? print_bold(io, text) : print(io, text)
        end
        println(io)
    end
    return nothing
end

# The plural is spelled out when adding an `s` does not make one: "2 processs" is
# the kind of thing a reader notices instead of the number in front of it.
plural(n::Integer, one::AbstractString, many::AbstractString = one * "s") =
    string(n, " ", n == 1 ? one : many)

# The same shape `Test` uses for its own Time column, so every duration a run
# prints reads the same way.
function fmt_seconds(s::Real)
    s < 60 && return string(round(s; digits = 1), "s")
    # A time no run takes, or not a number, which only a damaged run state holds, is
    # said as it is rather than in minutes that overflow an `Int`.
    s < 1.0e12 || return string(s, "s")
    m, rest = divrem(s, 60)
    return string(round(Int, m), "m", lpad(string(round(rest; digits = 1)), 4, "0"), "s")
end

### Run output #############################################################

"""
    label_prefix(io=stdout) -> String

The prefix everything Runtests says about a run starts with, indented by
[`GUTTER`](@ref) so that it lines up with the text inside a bracket.
"""
label_prefix(io::IO = stdout) =
    GUTTER * sprint(x -> printstyled(x, "[TEST] "; bold = true); context = :color => get(io, :color, false)::Bool)

# What a bracket's `┌ `, `│ ` and `└ ` occupy, as blanks.
const GUTTER = "  "

# Worker lifecycle, test items and the run's own report share one line shape:
#     ⚫ w1 · 16:30:28 · UP   · pid 48123 · threads 2,1
#     🔵 w1 · 16:30:28 · RUN  ·  1/11 · "passes" · at test/basics_test.jl:1
#     🟢 w1 · 16:30:29 · DONE ·  1/11 · "passes" · PASS ·   0.2s ( 3% compile) · maxrss 0.4 GiB
#     ⚪ w0 · 16:30:29 · INFO ·  3/11 · 0 failed · 2/2 workers · tree mem 1.1G (max 1.2G) · …
#        w1 · whatever a test item printed for itself
#
# A circle is the framework speaking, and its colour is the news: blue in flight,
# green passed, red not, yellow set aside, black the worker, white the run itself.
# What an item prints has no circle, since it is not the framework speaking.
# Every glyph is two columns wide in Unicode's tables and has no variation
# selector, which keeps the `w1` column in place; 🛠️ and ℹ️ are width 1 in the
# tables and width 2 in most terminals.
const MARK_ITEM = "  "   # as wide as a glyph, and blank
const MARK_RUNNING = "🔵"
const MARK_PASSED = "🟢"
const MARK_FAILED = "🔴"
const MARK_SET_ASIDE = "🟡"
const MARK_WORKER = "⚫"
const MARK_INFO = "⚪"

const PRECOMPILE_MARK_RUNNING = "🟦"
const PRECOMPILE_MARK_PASSED = "🟩"
const PRECOMPILE_MARK_FAILED = "🟥"
const PRECOMPILE_MARK_UNPRECOMPILABLE = "🟨"
const PRECOMPILE_MARK_WORKER = "⬛"
const PRECOMPILE_MARK_INFO = "⬜"

const FIELD = " · "
const WORKER_STATE_WIDTH = 4   # "DONE", "EXIT", "KILL", "LOST", "INFO"; "RUN" and "UP" are shorter
const STATE_WIDTH = 4          # "PASS"; the rarer outcomes are longer and may push the line
const TIME_WIDTH = 5           # "99.9s"

# One unit each, always: a column that switches between ms and s, or MiB and GiB,
# cannot be compared down the page at a glance.
fmt_gib(b::Real) = string(round(b / 2^30; digits = 1), " GiB")

# Four columns for the common outcomes; the rare ones are spelled out and may push
# the line.
short_state(state::ItemState) =
    state === PASSED ? "PASS" : state === FAILED ? "FAIL" : state === ERRORED ? "ERR" :
    state === SKIPPED ? "SKIP" : state === TIMEDOUT ? "TIMEOUT" :
    state === BROKEN_CHAIN ? "BROKEN" : state === CANCELLED ? "CANCELLED" : string(state)

# `Test`'s palette, so an outcome looks the same here as in `Test`'s summary.
state_color(state::ItemState) =
    state === PASSED ? :green : state === SKIPPED || state === CANCELLED ? Base.warn_color() :
    is_non_pass(state) ? Base.error_color() : :default
state_mark(state::ItemState) =
    state === PASSED ? MARK_PASSED : state === SKIPPED || state === CANCELLED ? MARK_SET_ASIDE :
    is_non_pass(state) ? MARK_FAILED : MARK_RUNNING

# The width of a name as `repr` writes it, without building the copy when there is
# nothing to escape, which is almost every name.
needs_escaping(s::AbstractString) = any(c -> c == '"' || c == '\\' || c == '$' || !isprint(c), s)
quoted_width(name::AbstractString) = needs_escaping(name) ? textwidth(repr(name)) : textwidth(name) + 2

# Written a byte at a time: the status line pads several numbers on every redraw.
function pad_to(io::IO, width::Integer, used::Integer)
    for _ in 1:(width - used)
        write(io, UInt8(' '))
    end
    return nothing
end

# Bounds on the name column: narrower is not worth aligning, wider is a column of
# blanks on a line nobody can read anyway.
const MIN_NAME_WIDTH = 12
const MAX_NAME_WIDTH = 60
# The column may leave this share of the names to overflow, and always at least
# this many: one wild name among five should not set the width for the other four.
const NAME_OUTLIER_SHARE = 10
const NAME_OUTLIER_ALLOWANCE = 2
# ...but covers a tail that is this close, rather than leave it to overflow.
const NAME_TAIL_SLACK = 8
# What the rest of a DONE line takes at its widest, for a caller that knows no plan.
const LINE_RESERVED = 82

"""
    name_width(names; columns = 0, reserved = LINE_RESERVED) -> Int

One width for the name column for the whole run, so the columns after it stay put:
the widest name once the allowed outliers are set aside, extended through the
names above it while each is within `NAME_TAIL_SLACK`. Two thousand ten-character
names and two of sixty get a ten-wide column and two long lines. `columns` is the
terminal's width, or `0` when there is none, and `reserved` what the rest of the line
must keep on it (`line_reserved`).
"""
function name_width(names; columns::Integer = 0, reserved::Integer = LINE_RESERVED)
    isempty(names) && return MIN_NAME_WIDTH
    widths = sort!([quoted_width(n) for n in names])
    n = length(widths)
    allowed = max(NAME_OUTLIER_ALLOWANCE, n ÷ NAME_OUTLIER_SHARE)
    wanted = widths[max(1, n - allowed)]
    for j in (max(1, n - allowed) + 1):n
        widths[j] - wanted <= NAME_TAIL_SLACK || break
        wanted = widths[j]
    end
    # The floor is on the budget, not the answer: names all eight wide want an
    # eight-wide column, not a floor's worth of blanks after each.
    budget = columns > 0 ? clamp(columns - reserved, MIN_NAME_WIDTH, MAX_NAME_WIDTH) : MAX_NAME_WIDTH
    return min(wanted, budget)
end

# What a DONE line of plan `p` takes besides its name, up to and with its outcome: the
# mark, the worker, the time, the word, the count, the package of a run of several,
# and the outcome. What follows, the time and memory it took, may wrap on a narrow
# terminal; the item and how it went stay on the line.
function line_reserved(p::Plan)
    worker = single_process(p) ? 0 : slot_label_width(nslots(p)) + length(FIELD)
    count = 2 * ndigits(nitems(p)) + 1 + length(FIELD)
    package = is_combined(p) ? maximum(textwidth, p.packages.name) + length(FIELD) : 0
    return 3 + worker + 8 + length(FIELD) + WORKER_STATE_WIDTH + length(FIELD) + count + package +
           length(FIELD) + STATE_WIDTH
end

# The name column of plan `p`'s lines, and of its plan as a dry run prints it, for the
# terminal the run writes to.
run_name_width(p::Plan) = name_width(p.items.name; columns = terminal_columns(stdout isa Base.TTY), reserved = line_reserved(p))

# The wall clock as lines write it, formatted once a second: `strftime` builds a
# string per call, and there are two lines for every item. Lines come from several
# tasks, so the second and its text are swapped in as one atomic reference.
mutable struct ClockText
    @atomic now::Pair{Int, String}
end
const CLOCK_TEXT = ClockText(-1 => "")

function clock_now()
    sec = floor(Int, time())
    last = @atomic CLOCK_TEXT.now
    first(last) == sec && return last.second
    text = Libc.strftime("%H:%M:%S", sec)
    @atomic CLOCK_TEXT.now = sec => text
    return text
end

# How wide a worker's label, `w` and its number, is written: as wide as the run's
# widest, so that what follows lines up past the ninth worker. Set as a run starts; a
# process runs one at a time.
const SLOT_LABEL_WIDTH = Ref(2)

slot_label_width(nslots::Integer) = 1 + ndigits(max(nslots, 1))

# The start every line shares: glyph, the worker it is about (none in a run
# without workers), and the time. The clock is passed in because the status line,
# redrawn after everything the run prints, has a cheaper way to get it.
function print_line_head(io::IO, mark::AbstractString, slot_id, clock::AbstractString)
    print(io, mark, " ")
    if slot_id !== nothing
        print(io, "w")
        print_int(io, slot_id)
        pad_to(io, SLOT_LABEL_WIDTH[], 1 + ndigits(slot_id))
        print(io, FIELD)
    end
    print(io, clock, FIELD)
    return nothing
end

function print_word(io::IO, word::AbstractString)
    bold = get(io, :color, false)::Bool
    bold && print(io, "\e[1m")
    print(io, word)
    pad_to(io, WORKER_STATE_WIDTH, textwidth(word))
    bold && print(io, "\e[22m")
    print(io, FIELD)
    return nothing
end

# `text` padded to `width` in `color`, byte for byte as `printstyled` writes it,
# without the closure and the padded copy it builds: two lines per item use it.
# A colour is a name or, as `JULIA_ERROR_COLOR=196` makes `Base.error_color()`, a
# number from 0 to 255.
function print_colored(io::IO, text::AbstractString, width::Integer, color::Union{Symbol, Int})
    on = get(io, :color, false)::Bool
    on && print(io, Base.text_colors[color])
    print(io, text)
    pad_to(io, width, textwidth(text))
    on && color !== :default && print(io, Base.text_colors[:default])
    return nothing
end

# `printstyled` builds a closure and a padded string per call, and the status line
# is redrawn after every line the run prints.
function print_bold(io::IO, text::AbstractString)
    bold = get(io, :color, false)::Bool
    bold && print(io, "\e[1m")
    print(io, text)
    bold && print(io, "\e[22m")
    return nothing
end

# Text built for printing, in colour when the run's own output is, in a buffer that
# starts at a printed line's size, colour codes included, so that a line does not
# grow it several times over.
const LINE_BYTES = 160
styled(f) = sprint(f; context = :color => get(stdout, :color, false)::Bool, sizehint = LINE_BYTES)

# A line the run says about itself.
say(run, parts...) = printline(run, string(label_prefix(), parts...))

# A line of a worker's life, `UP`, `EXIT` and the like, under `mark`.
lifecycle_line(run, mark::AbstractString, id, state::AbstractString, text::AbstractString) = printline(run, styled() do io
    print_line_head(io, mark, id, clock_now())
    print_word(io, state)
    print(io, text)
end)

print_worker_line(run, slot_id, state::AbstractString, text::AbstractString) =
    lifecycle_line(run, MARK_WORKER, slot_id, state, text)

# The same line for a precompile helper: a black square where a test worker's circle
# sits, so its UP and EXIT lines read as the same lifecycle in another colour.
print_helper_line(run, id, state::AbstractString, text::AbstractString) =
    lifecycle_line(run, PRECOMPILE_MARK_WORKER, id, state, text)

"""
    item_line(slot_id, i, total, shown, width, attempt, attempts, how) -> String

An item's RUN line when `how` is where it is, and its DONE line when `how` is how
it went: `(; state, elapsed_ns, compile_ns, maxrss)`. `shown` is its name as the
line writes it, quoted or shortened (see [`item_names`](@ref)), in a column `width`
wide. A retry is the same item again, so it gets the same line with a field of its
own; `total` is 0 when there is no count to give. In a run of several packages,
`package` names the item's, in a column `package_width` wide.
"""
item_line(slot_id, i, total, shown, width, attempt, attempts, how; package::AbstractString = "", package_width::Integer = 0) =
styled() do io
    done = !(how isa AbstractString)
    print_line_head(io, done ? state_mark(how.state) : MARK_RUNNING, slot_id, clock_now())
    print_word(io, done ? "DONE" : "RUN")
    if total > 0
        print_int(io, i, ndigits(total)); write(io, UInt8('/')); print_int(io, total); print(io, FIELD)
    end
    if !isempty(package)
        print(io, package)
        pad_to(io, package_width, textwidth(package))
        print(io, FIELD)
    end
    # A name longer than the column pushes the rest out rather than being cut: the
    # name is what identifies the item, and a shortened one still does.
    print(io, shown)
    pad_to(io, width, textwidth(shown))
    # After the outcome on a DONE line, which keeps the outcome in its column.
    retry() = attempt > 1 &&
        (print(io, FIELD, "retry "); print_int(io, attempt - 1); print(io, " of "); print_int(io, max(attempts - 1, 1)))
    done || retry()
    print(io, FIELD)
    if done
        pct = how.elapsed_ns > 0 ? round(Int, 100 * how.compile_ns / how.elapsed_ns) : 0
        print_colored(io, short_state(how.state), STATE_WIDTH, state_color(how.state))
        retry()
        # Rounded to a tenth inside `print_1dp`, without a string.
        print(io, FIELD); print_1dp(io, how.elapsed_ns / 1.0e9, TIME_WIDTH - 1)
        print(io, "s ("); print_int(io, pct, 2); print(io, "% compile)")
        # `tree max`: the worker with what it started, over the attempt; `maxrss`: one
        # process, since it started.
        print(io, FIELD, get(how, :tree, false) ? "tree max " : "maxrss ")
        print_1dp(io, how.maxrss / 2^30); print(io, " GiB")
    else
        print(io, "at ")
        print_bold(io, how)
    end
end

outcome(r::ItemResult) = (; r.state, r.stats.elapsed_ns, r.stats.compile_ns, r.stats.maxrss)

"""
    parse_record(line) -> Union{Nothing, NamedTuple}

A worker's record of an item starting or finishing (`RuntestsWorkers.record_run`,
`record_done`) as `(; i, attempt, how)`, with `how === nothing` for a start; or
`nothing` for any other line.
"""
function parse_record(line::AbstractString)
    startswith(line, RECORD_MARK) || return nothing
    # Cut at each space by position and parsed into a tuple, with no string built for
    # any field: two of these arrive for every item.
    stop = ncodeunits(line)
    lo = ncodeunits(RECORD_MARK) + 1
    word = :other
    # `Int64` rather than `Int`: in 32 bits, nanoseconds pass 2^31 in 2.1 seconds.
    n, k = ntuple(_ -> Int64(0), Val(6)), -1   # k: the numbers read, after the word
    while true
        sp = something(findnext(' ', line, lo), stop + 1)
        field = SubString(line, lo, prevind(line, sp))
        if k < 0
            word = field == "RUN" ? :run : field == "DONE" ? :done : :other
        else
            v = tryparse(Int64, field)
            (v === nothing || k == length(n)) && return nothing
            n = Base.setindex(n, v, k + 1)
        end
        k += 1
        sp > stop && break
        lo = sp + 1
    end
    word === :run && k == 2 && return (; i = n[1], attempt = n[2], how = nothing)
    (word === :done && k == 6 && 0 <= n[3] <= Int(CANCELLED)) || return nothing
    return (; i = n[1], attempt = n[2], how = (; state = ItemState(n[3]), elapsed_ns = n[4], compile_ns = n[5], maxrss = n[6]))
end

# Where the time before the first test item went: on a large suite, the wait.
function print_startup(io::IO, s::Startup)
    parts = String[]
    s.files > 0      && push!(parts, string("scan ", fmt_seconds(s.files)))
    s.plan > 0.005   && push!(parts, string("plan ", fmt_seconds(s.plan)))
    s.setup > 0.005  && push!(parts, string("setup ", fmt_seconds(s.setup)))
    isempty(parts) || println(io, "startup: ", join(parts, " · "))
    return nothing
end

# The packages of a run of several: each with its items, the isolated ones said so,
# and what the plan notes of those left out.
function print_packages(io::IO, p::Plan)
    is_combined(p) || return nothing
    counts = zeros(Int, length(p.packages))
    foreach(k -> counts[k] += 1, p.items.package)
    println(io, "packages: ", join((string(p.packages.name[k], " (", plural(counts[k], "item"),
                                          p.packages.isolated[k] ? ", isolated" : "", ")") for k in eachindex(counts)), ", "))
    foreach(note -> println(io, note), p.notes)
    return nothing
end

"""
    print_run_header(run)

What the call does not show: which Runtests and Julia, how much work, how many
processes with what given to them, and the environment it resolved to.
"""
function print_run_header(run)
    p = run.plan
    head = sprint(io -> print_work(io, p, length(run.slots); seed = p.cfg.seed))
    body = sprint() do io
        print_selection(io, p)
        # The project's path in the run-state path's colour, as the log paths are.
        env = something(Base.active_project(), "none")
        println(io, "env: ", styled(x -> printstyled(x, env; color = :light_black)))
        print_machine(io)
        print_packages(io, p)
        print_startup(io, p.startup)
        print_profiles(io, p)
        print_env_settings(io, p.cfg)
        print_coverage_setting(io, p.cfg)
    end
    print_label_block(run, head, body)
    return nothing
end

# What the workers share: the CPU threads and the memory of the machine, as the
# progress line counts them. In a container the memory is what the container may use.
function print_machine(io::IO)
    used, total = Platform.machine_memory()
    print(io, "machine: ", Platform.cpu_count(), " CPU threads")
    total > 0 && print(io, " · ", fmt_gib(total), " memory, ", fmt_gib(total - used), " available")
    println(io)
    return nothing
end

"""
    print_label_block(run, head, body)

Something Runtests says that runs to more than one line, drawn in a bracket so that it
reads as one block among the workers' output. With nothing under its first line it
is printed as the plain line it is.
"""
print_label_block(run, head::AbstractString, body::AbstractString) = printline(run, label_block(head, body))

label_block(head::AbstractString, body::AbstractString) =
    isempty(strip(body)) ? string(label_prefix(), head) : bracket(body, "[TEST]", head, "", :default)

"""
    printline(run, text)

The one way anything reaches the terminal during a run: erase the pinned status
line, write `text` whole, and put the status line back, all under the printer lock,
so a log record, a worker's output and the status line never share a line.
"""
function printline(run, text::AbstractString)
    @lock run.printer begin
        m = run.monitor
        if m === nothing || !drawing(m)
            print(stdout, text)
            endswith(text, "\n") || println(stdout)
            flush(stdout)
        else
            write(stdout, status_update!(m, text))
            flush(stdout)
        end
    end
    return nothing
end

"""
    write_now(io, text)

Write `text` to `io` before returning, without the event loop. A write to a pipe or a
terminal otherwise waits for libuv to complete it, and an exit hook can run where
nothing ever will: Julia 1.12 exits on Ctrl-C from wherever its first thread was.
What a full pipe still refuses after two seconds is dropped, since an exit that
hangs is worse than one that says less. On Unix; elsewhere, and for a stream libuv
does not drive, an ordinary write.
"""
function write_now(io::IO, text::AbstractString)
    if !(Sys.isunix() && io isa Base.LibuvStream)
        print(io, text)
        flush(io)
        return nothing
    end
    fd = Base._fd(io)
    s = String(text)
    deadline = time() + 2.0
    GC.@preserve s begin
        at, left = pointer(s), sizeof(s)
        while left > 0
            n = ccall(:write, Cssize_t, (RawFD, Ptr{UInt8}, Csize_t), fd, at, left)
            if n >= 0
                at += n
                left -= n
            elseif Libc.errno() in (Libc.EAGAIN, Libc.EINTR) && time() < deadline
                Libc.systemsleep(0.001)
            else
                break
            end
        end
    end
    return nothing
end

"""
    RunLogger

Routes every log record of a run through [`printline`](@ref), formatted whole and
written once: a `ConsoleLogger` on `stdout` writes a record in several pieces, and
a warning ends up spliced into the status line.
"""
struct RunLogger{L <: Logging.AbstractLogger} <: Logging.AbstractLogger
    parent::L
    run::Any
end

Logging.min_enabled_level(l::RunLogger) = Logging.min_enabled_level(l.parent)
Logging.shouldlog(l::RunLogger, args...) = Logging.shouldlog(l.parent, args...)
Logging.catch_exceptions(l::RunLogger) = Logging.catch_exceptions(l.parent)

function Logging.handle_message(
        l::RunLogger, level, message, _module, group, id,
        file, line; kwargs...
    )
    printline(l.run, styled() do io
        Logging.handle_message(Logging.ConsoleLogger(io, Logging.BelowMinLevel), level, message, _module, group, id, file, line; kwargs...)
    end)
    return nothing
end

print_failfast(run, i::ItemIdx) = say(run, "stopping after ", repr(run.plan.items.name[i]), " failed (failfast)")

"""
    print_conclusion(run, ended = :finished)

The block that closes a run. On a terminal it lands where the progress line was,
so the last thing on screen says how the run went rather than which items
happened to finish last. `ended` is `:interrupted` or `:stalled` for a run that was
stopped, which then says how far it got.
"""
print_conclusion(run, ended::Symbol = :finished) = printline(run, conclusion_text(run, ended))

# The text of `print_conclusion`.
function conclusion_text(run, ended::Symbol = :finished)
    p = run.plan
    st = run.statuses
    elapsed = fmt_seconds(time() - run.t0)
    tally = state_tally(st.state)
    # A run that was stopped got through some of its items, and how many is the news.
    head = string(
        ended !== :finished ?
            string(ended === :stalled ? "stopped as hung after " : "interrupted after ",
                   count(s -> s !== UNSEEN && s !== CANCELLED, st.state), " of ",
                   plural(nitems(p), "test item"), " in ", elapsed) :
            string("ran ", plural(nitems(p), "test item"), " in ", elapsed,
                   single_process(p) ? " in this process" : string(" on ", plural(length(run.slots), "worker"))),
        isempty(tally) ? ", all passed" : string(", ", join(tally, ", "))
    )
    body = styled() do io
        monitor, coverage = run.monitor, run.coverage
        monitor === nothing || print_memory_summary(io, monitor; indent = "")
        coverage === nothing || print_coverage(io, coverage, p.root)
        rs = run.runstate
        rs isa RunStateSet && print_package_lines(io, run, rs)
        if rs isa RunStateFile
            # The run's directory: its record, and what its items printed and kept.
            print(io, "run state: ")
            printstyled(io, rundata_dir(rs.path); color = :light_black)
            println(io)
        end
        if (rs isa RunStateFile || rs isa RunStateSet) && !isempty(run.exported)
            print(io, "copied to: ")
            printstyled(io, run.exported; color = :light_black)
            println(io)
        end
        print_evidence_kept(io, run)
        # What to type next, for whoever reads this in a CI log as much as here.
        failing(i) = is_non_pass(st.state[i]) && st.state[i] !== CANCELLED && st.state[i] !== RUNNING
        if rs isa RunStateFile && any(failing, 1:nitems(p))
            print(io, "run the failing items again: ")
            printstyled(io, "Runtests.runtestsf()"; bold = true)
            if !isempty(run.exported)
                print(io, ", or where the copy is: ")
                printstyled(io, "Runtests.runtestsf(replay = ", repr(basename(rundata_dir(rs.path))), ")"; bold = true)
            end
            println(io)
        elseif rs isa RunStateSet
            ks = unique!([p.items.package[i] for i in 1:nitems(p) if failing(i) && rs.files[p.items.package[i]] !== nothing])
            if !isempty(ks)
                print(io, "run the failing items again: ")
                printstyled(io, "Runtests.runtestsf()"; bold = true)
                println(io, " in ", join((rel_slash(p.packages.root[k], p.root) for k in sort!(ks)), ", "))
            end
        end
    end
    return label_block(head, body)
end

# A line for each package of a run of several: its items, those that did not pass,
# and where its run state and logs are.
function print_package_lines(io::IO, run, rs::RunStateSet)
    p, st = run.plan, run.statuses
    npkg = length(rs.files)
    total = zeros(Int, npkg)
    bad = zeros(Int, npkg)
    for i in 1:nitems(p)
        k = p.items.package[i]
        total[k] += 1
        is_non_pass(st.state[i]) && (bad[k] += 1)
    end
    for k in 1:npkg
        print(io, p.packages.name[k], ": ", plural(total[k], "test item"), bad[k] == 0 ? "" : string(", ", bad[k], " not passed"))
        if rs.files[k] === nothing
            print(io, " · no run state, it could not be written; logs in ")
            printstyled(io, run.logdirs[k]; color = :light_black)
        else
            print(io, " · run state ")
            printstyled(io, rundata_dir(rs.files[k].path); color = :light_black)
        end
        println(io)
    end
    return nothing
end

# The attempts whose evidence was kept, an item that passed on a retry among them,
# each where it is: in the run's logs, or, without a run state, in a directory of its
# own. Taken with `trylock`: the exit hook says this too, and a task the exit froze
# may hold the lock.
function print_evidence_kept(io::IO, run)
    trylock(run.lock) || return nothing
    kept = try
        sort(run.evidence)
    finally
        unlock(run.lock)
    end
    isempty(kept) && return nothing
    p = run.plan
    println(io, "artifacts of ", plural(length(kept), "failed attempt"), ":")
    for (i, attempt) in kept
        # Which attempt, where the item could have had several.
        which = attempts_for(p, i) > 1 ? string(" attempt ", attempt) : ""
        print(io, "  ", repr(p.items.name[i]), which, ": ")
        printstyled(io, attempt_artifacts(run, i, attempt); color = :light_black)
        println(io)
    end
    return nothing
end

# Everything that is not a plain pass, in the order a reader cares about.
function state_tally(states)
    out = String[]
    for (state, label) in STATE_LABELS
        state === PASSED && continue
        c = count(==(state), states)
        c > 0 && push!(out, string(c, " ", label))
    end
    return out
end

const STATE_LABELS = (
    PASSED => "passed", FAILED => "failed", ERRORED => "errored", TIMEDOUT => "timed out",
    BROKEN_CHAIN => "broken by a dead worker", SKIPPED => "skipped", CANCELLED => "cancelled",
    UNSEEN => "did not run", RUNNING => "still running",
)

# Why a worker ended, as a person says it.
worker_end_text(by::Symbol) =
    by === :close ? "closed by the run" : by === :timeout ? "killed for a timeout" :
    by === :connection_lost || by === :process_exit ? "died" : by === :memory_guard ? "killed by the memory guard" :
    by === :interrupt ? "killed by an interrupt" : by === :init_failed ? "its init expression failed" :
    replace(String(by), '_' => ' ')

# A run's testsets are built after the items finish, so both ends are set from what
# the run recorded. 1.13 takes the start as a keyword and holds `time_end`
# atomically; 1.12 has neither.
@static if VERSION >= v"1.13"
    started_testset(name::AbstractString; verbose::Bool, at::Float64) =
        Test.DefaultTestSet(name; verbose, time_start = at)
    finished_at!(ts::Test.DefaultTestSet, at::Float64) = (@atomic ts.time_end = at)
else
    function started_testset(name::AbstractString; verbose::Bool, at::Float64)
        ts = Test.DefaultTestSet(name; verbose)
        ts.time_start = at
        return ts
    end
    finished_at!(ts::Test.DefaultTestSet, at::Float64) = (ts.time_end = at)
end

function report(run)
    p = run.plan
    st = run.statuses
    # `Test` prints `time_end - time_start` in its own Time column, so the run's
    # times are put where it already looks rather than into a column of our own.
    # The root's clock starts when the run did, so its row is the run's wall time.
    root = started_testset(p.cfg.testset_name; verbose = true, at = run.t0)
    nf = length(p.files)
    file_seen = falses(nf)
    file_pkg = zeros(Int32, nf)
    file_start = fill(Inf32, nf)
    file_end = fill(-Inf32, nf)
    for i in 1:nitems(p)
        fid = p.items.fileidx[i]
        file_seen[fid] = true
        file_pkg[fid] = p.items.package[i]
        if st.state[i] !== UNSEEN
            s = st.start[i]
            e = s + st.elapsed[i]
            s < file_start[fid] && (file_start[fid] = s)
            e > file_end[fid] && (file_end[fid] = e)
        end
    end
    combined = is_combined(p)
    byfile = Vector{Union{Nothing, Test.DefaultTestSet}}(nothing, nf)
    for fid in 1:nf
        file_seen[fid] || continue
        name = combined ? relpath_or_path(p.files[fid], p.packages.root[file_pkg[fid]]) : p.relfiles[fid]
        byfile[fid] = if isfinite(file_start[fid])
            ts = started_testset(name; verbose = p.cfg.verbose, at = run.t0 + file_start[fid])
            finished_at!(ts, run.t0 + file_end[fid])
            ts
        else
            Test.DefaultTestSet(name; verbose = p.cfg.verbose)
        end
    end
    for i in 1:nitems(p)
        ts = st.testsets[i]
        ts === nothing && continue
        Test.record(byfile[p.items.fileidx[i]]::Test.DefaultTestSet, ts)
    end
    # A run of several packages: a testset for each package, its files in it.
    packages = combined ? [started_testset(name; verbose = true, at = run.t0) for name in p.packages.name] :
        Test.DefaultTestSet[]
    for fid in 1:nf
        fts = byfile[fid]
        fts === nothing && continue
        Test.record(combined ? packages[file_pkg[fid]] : root, fts)
    end
    for ts in packages
        finished_at!(ts, time())
        Test.record(root, ts)
    end
    record_unrun!(root, run)
    print_conclusion(run)
    Test.finish(root)
    return root
end

"""
    RunTestSet

What [`runtests`](@ref) and [`runtests_mono`](@ref) return: a testset that prints as
one line. A one-package run has a testset per file; a combined run has a testset per
participating package, with that package's files beneath it. `RunTestSet` forwards
other testset operations to its `Test.DefaultTestSet`, `ts.testset`, whose fields
also read through it. Recorded into a parent or finished inside one, it is the
`DefaultTestSet` that goes into the parent, so no testset tree holds anything else.
"""
struct RunTestSet <: Test.AbstractTestSet
    testset::Test.DefaultTestSet
end

# `@testset RunTestSet "name" begin … end`, which names the type to make.
RunTestSet(description::AbstractString; kwargs...) = RunTestSet(Test.DefaultTestSet(description; kwargs...))

Base.getproperty(ts::RunTestSet, f::Symbol) =
    f === :testset ? getfield(ts, :testset) : getproperty(getfield(ts, :testset), f)
Base.propertynames(ts::RunTestSet, private::Bool = false) =
    (:testset, propertynames(getfield(ts, :testset), private)...)

Test.record(ts::RunTestSet, res; kwargs...) = Test.record(ts.testset, res; kwargs...)
Test.record(parent::Test.DefaultTestSet, ts::RunTestSet) = Test.record(parent, ts.testset)
function Test.finish(ts::RunTestSet; kwargs...)
    Test.finish(ts.testset; kwargs...)
    return ts
end
Test.results(ts::RunTestSet) = Test.results(ts.testset)
Test.print_verbose(ts::RunTestSet) = Test.print_verbose(ts.testset)
Test.get_test_counts(ts::RunTestSet) = Test.get_test_counts(ts.testset)
Test.get_alignment(ts::RunTestSet, depth::Int) = Test.get_alignment(ts.testset, depth)
Test.format_duration(ts::RunTestSet) = Test.format_duration(ts.testset)
Test.filter_errors(ts::RunTestSet) = Test.filter_errors(ts.testset)
@static if isdefined(Test, :get_rng)   # from Julia 1.12
    Test.get_rng(ts::RunTestSet) = Test.get_rng(ts.testset)
    Test.set_rng!(ts::RunTestSet, rng::Random.AbstractRNG) = Test.set_rng!(ts.testset, rng)
end
Test.print_test_results(ts::RunTestSet, depth_pad = 0) = Test.print_test_results(ts.testset, depth_pad)
@static if isdefined(Test, :anynonpass)
    Test.anynonpass(ts::RunTestSet) = Test.anynonpass(ts.testset)
end

# One line: the testset's name and what it counted, inside other output too.
function Base.show(io::IO, ts::RunTestSet)
    tc = Test.get_test_counts(ts.testset)
    counts = (tc.passes + tc.cumulative_passes => "passed", tc.fails + tc.cumulative_fails => "failed",
              tc.errors + tc.cumulative_errors => "errored", tc.broken + tc.cumulative_broken => "broken")
    shown = [string(n, " ", what) for (n, what) in counts if n > 0]
    print(io, repr(ts.testset.description), " testset: ", isempty(shown) ? "no tests" : join(shown, ", "))
    ts.testset.time_end > 0 && print(io, " · ", Test.format_duration(ts.testset))
    return nothing
end

# An item that never ran is not an item that passed. A run cut short (an `init`
# that will not start, a dead slot, failfast) records what is missing, or the
# emptiest run would be the greenest.
function record_unrun!(root::Test.AbstractTestSet, run)
    p = run.plan
    st = run.statuses
    idxs = [i for i in 1:nitems(p) if st.state[i] === UNSEEN || st.state[i] === CANCELLED]
    isempty(idxs) && return nothing
    shown = join((repr(p.items.name[i]) for i in Iterators.take(idxs, 5)), ", ")
    why = is_cancelled(run.queues) ? "did not run because the run stopped early" :
        "have no outcome, though the run was not stopped (a Runtests bug, logged above)"
    msg = string(length(idxs), " of ", plural(nitems(p), "test item"), " ", why, ": ", shown, length(idxs) > 5 ? ", …" : "")
    # The conclusion block above says the same thing in the run's own words; this
    # record exists so the verdict is wrong when the run was.
    add_error!(root, msg, source_of(p, first(idxs)))
    return nothing
end

# Where an item is, as a stack frame would say it.
source_of(p::Plan, i::Integer) = LineNumberNode(Int(p.items.line[i]), p.files[p.items.fileidx[i]])

# An error the run synthesized, recorded into `ts` without `Test` printing it: the
# run prints what it records itself. `Test.Error` renders its message from the
# exception stack, so the stack carries it. The backtrace has the element type
# `catch_backtrace` gives, which `Test` asserts before it scrubs one.
function add_error!(ts::Test.AbstractTestSet, msg::AbstractString, source::LineNumberNode)
    stack = Base.ExceptionStack([(exception = ErrorException(msg), backtrace = Union{Ptr{Nothing}, Base.InterpreterIP}[])])
    with_testset_printing(false) do
        Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), ErrorException(msg), stack, source))
    end
    return ts
end

"""
    report_item!(run, o)

Everything an item has to say, written when it finishes and in one piece so that
no other worker's output lands inside it: its failures, then its captured logs.
`Test` would print failures where they are recorded, on a worker with printing
switched off, so the coordinator prints them.
"""
function report_item!(run, o)
    p = run.plan
    i, state = o.i, o.state
    # A cancelled item has nothing of its own to show; the conclusion counts them.
    state === CANCELLED && return nothing
    # Having nothing to say is the common case — a passing item in `:issues` mode —
    # and everything below this line allocates to find that out.
    (is_non_pass(state) || wants_log(p.cfg.logs, state) || p.cfg.verbose) || return nothing
    body = styled() do io
        # A coordinator-written outcome — a timeout, a dead worker — is already
        # stated in this block's first line; showing the record it synthesized
        # would say it again, word for word.
        is_non_pass(state) && !o.synthetic && print_failures(io, o.testset)
        print_item_log(io, run, i, o.attempt, state)
        # Where the attempt's evidence is: written, or about to be collected.
        if is_non_pass(state) && o.artifacts != 0
            print(io, "artifacts: ")
            printstyled(io, attempt_artifacts(run, i, o.attempt); color = :light_black)
            println(io)
        end
    end
    isempty(body) && return nothing
    total = nitems(p)
    label = string("[", lpad(o.n, ndigits(total)), "/", total, "] ", short_state(state))
    rest = string(repr(p.items.name[i]), isempty(o.note) ? "" : string(" · ", o.note))
    footer = string(
        "@ ", itemfile(p, i), ":", p.items.line[i], on_worker(run, o.slot)
    )
    printline(run, bracket(strip_root(body, p.root), label, rest, footer, state_color(state)))
    return nothing
end

"""
    bracket(body, label, rest, footer, color) -> String

`body` drawn in the shape `Logging` gives a multi-line record: `┌`, the coloured
`label` and `rest` on the first line, `│` down the side, and `└` on the last, with
`footer` dimmed.
"""
function bracket(
        body::AbstractString, label::AbstractString, rest::AbstractString,
        footer::AbstractString, color
    )
    # Coloured like a log record: the gutter and the label carry the colour, what
    # follows is ordinary text, and the location at the bottom is dimmed.
    return styled() do io
        printstyled(io, "┌ ", label; color, bold = true)
        isempty(rest) || print(io, " ", rest)
        println(io)
        lines = collect(eachsplit(chomp(body), '\n'))
        # `└` carries the last thing there is, as a log record's does: the location
        # when there is one, and otherwise the final line of the body.
        tail = isempty(footer) && !isempty(lines) ? pop!(lines) : nothing
        for line in lines
            printstyled(io, "│ "; color, bold = true)
            println(io, line)
        end
        printstyled(io, isempty(footer) && tail === nothing ? "└" : "└ "; color, bold = true)
        tail === nothing ? (isempty(footer) || printstyled(io, footer; color = :light_black)) : print(io, tail)
        println(io)
    end
end

"""
    strip_root(text, root)

`text` with the project's directory taken off every path in it. Paths stay absolute
while an item runs, because `@__FILE__` and `@__DIR__` depend on them; shortening
them on the way out cannot change what the item's code means.
"""
function strip_root(text::AbstractString, root::AbstractString)
    isempty(root) && return text
    out = text
    # The stacktrace printer contracts the home directory, so the same path can
    # arrive spelled two ways; and on Windows with either separator, since Julia
    # writes `\` and much else writes `/`.
    for r in unique((root, Base.contractuser(root))), sep in PATH_SEPARATORS
        out = replace(out, r * sep => "")
    end
    return out
end

function print_failures(io::IO, ts::Union{Nothing, Test.AbstractTestSet})
    ts === nothing && return nothing
    for r in collect_failures(ts)
        show(io, r)
        println(io)
    end
    return nothing
end

# `:eager` output was relayed as it happened; `:batched` prints every item's
# output, `:issues` only that of items with something wrong, and `:quiet` none,
# leaving it in the run's logs.
wants_log(logs::Symbol, state::ItemState) =
    logs === :batched || (logs === :issues && is_non_pass(state))

function print_item_log(io::IO, run, i::ItemIdx, attempt::Integer, state::ItemState)
    p = run.plan
    wants_log(p.cfg.logs, state) || return nothing
    path = item_log(run, i, max(attempt, 1))
    has_logs = isfile(path) && filesize(path) > 0
    # An item that failed and said nothing is worth saying so about: silence there
    # is a fact about the failure, not a reason to print nothing.
    (has_logs || is_non_pass(state) || p.cfg.verbose) || return nothing
    if !has_logs
        # One line, so the inline bracket of a one-line log record, `[`.
        printstyled(io, "[ No captured logs"; bold = true, color = Base.info_color())
        println(io)
        return nothing
    end
    # A bracket of its own inside the item's, written through rather than indented,
    # so the item's own log records and colours come out as its author meant.
    logs = trim_blank_lines(open(io -> read(io, String), path, "r"))
    print(io, bracket(logs, "Captured logs", "", "", Base.info_color()))
    return nothing
end

# A crash dump or a triggered profile tends to start and end with blank lines,
# which inside a bracket become empty gutter rows.
trim_blank_lines(text::AbstractString) =
    replace(replace(text, r"\A(?:[ \t]*\n)+" => ""), r"(?:\n[ \t]*)+\z" => "")

# With no workers there is no worker to name.
on_worker(run, slot::Integer) =
    (single_process(run.plan) || slot == 0) ? "" : string(" on worker ", slot)

# The failure report of an attempt, beside its log.
failure_path(prefix::String, index::Integer, attempt::Integer) = string(prefix, index, "_", attempt, ".failure.txt")

# Where one attempt at one item writes what it prints.
item_log_path(prefix::String, index::Integer, attempt::Integer) = string(prefix, index, "_", attempt, ".log")

function collect_failures(ts::Test.AbstractTestSet, out = Any[])
    for r in ts.results
        if r isa Test.Fail || r isa Test.Error
            push!(out, r)
        elseif r isa Test.AbstractTestSet
            collect_failures(r, out)
        end
    end
    return out
end
