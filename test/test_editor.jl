# The editor protocol: the JSON it speaks, the listing, and a session driven over
# streams the way an editor drives one, in this process and in a process of its own.

using Runtests.Private: write_json, read_json, json, list_items, PROTOCOL_VERSION

# A server in this process, over two streams, with its events arriving on a channel.
struct EditorSession
    input::Base.BufferStream
    output::Base.BufferStream
    events::Channel{Any}
    task::Task
end

function open_session(dir; config = nothing)
    input, output = Base.BufferStream(), Base.BufferStream()
    task = @async Runtests.serve(dir; config, input, output)
    events = Channel{Any}(Inf)
    @async begin
        for line in eachline(output)
            put!(events, read_json(line))
        end
        close(events)
    end
    return EditorSession(input, output, events, task)
end

send(s::EditorSession, x) = println(s.input, json(x))
send(s::EditorSession, x::AbstractString) = println(s.input, x)
# Bounded: a server that stops answering fails the test rather than holding it.
function next_event(s::EditorSession; timeout = 120)
    t = Timer(_ -> close(s.events, ErrorException("no event from the server in $(timeout)s")), timeout)
    try
        return take!(s.events)
    finally
        close(t)
    end
end
# Every event up to and including the first `pred` holds for.
function events_until(pred, s::EditorSession)
    seen = Any[]
    while true
        e = next_event(s)
        push!(seen, e)
        pred(e) && return seen
    end
end
# `serve` leaves the stream it writes to open: it is the caller's.
close_session(s::EditorSession) = (send(s, (; command = "shutdown")); wait(s.task); close(s.output))

item(name, body = "@test true"; opts = "") = "@testitem \"$name\" $opts begin\n    $body\nend\n"

@testset "editor protocol" begin
    @testset "JSON: what is written reads back, escapes and all" begin
        @test json((; a = 1, b = "x\n\"y\"\\", c = Any[1.5, nothing, true, false], d = Dict("k" => :v))) ==
              "{\"a\":1,\"b\":\"x\\n\\\"y\\\"\\\\\",\"c\":[1.5,null,true,false],\"d\":{\"k\":\"v\"}}"
        @test json("tab\tnul\0bell\a") == "\"tab\\tnul\\u0000bell\\u0007\""
        # What JSON cannot carry: a non-finite number is null, invalid UTF-8 a
        # replacement character.
        @test json([NaN, Inf, -Inf]) == "[null,null,null]"
        @test json(String([0x61, 0xff, 0x62])) == "\"a\\ufffdb\""
        # A `Float32` with the digits it has, not the ones a `Float64` would show.
        @test json(Float32(0.1)) == "0.1"
        for v in Any[
                Dict{String, Any}("name" => "é😀\n", "n" => -12, "x" => 2.5e-7, "list" => Any[Any[], Dict{String, Any}()],
                                  "flags" => Any[true, false, nothing]),
                Any["", "\\", "\"", "/"], 0, -1, 1.0, typemax(Int64),
            ]
            @test read_json(json(v)) == v
        end
        @test read_json("\"\\u00e9\\ud83d\\ude00\\/\"") == "é😀/"
        @test read_json("\"\\ud83d\"") == "\ufffd"         # half a surrogate pair is no character
        @test read_json(" [1 , 2.0, 3e2 ] ") == Any[1, 2.0, 300.0]
        @test read_json("-0.5") == -0.5
        # Malformed text says what was expected, and where.
        for (bad, expected) in (
                "{\"a\" 1}" => "`:`", "[1, 2" => "`,` or `]`", "\"open" => "a closing `\"`",
                "012" => "`.`, `e` or the end of the number", "{} x" => "the end of the text",
                "\"a\tb\"" => "a character other than a raw control character", "\"\\q\"" => "after `\\`",
                "tru" => "a value", "" => "a value", "{1: 2}" => "a key in double quotes",
            )
            err = try
                read_json(bad); nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin(expected, err.msg) && occursin("at byte", err.msg)
        end
    end

    @testset "the listing holds every item, and every problem a run would stop on" begin
        dir = make_pkg(
            "Listed",
            "test/a_test.jl" => string(item("first"), "\n# a comment\n\n",
                                       item("second"; opts = "tags=[:fast, :db] timeout=30 retries=2 skip=(1 == 2)"),
                                       item("chained"; opts = "chain=:c failfast=true")),
            "test/b_test.jl" => item("alone"; opts = "sandbox=true") * item("profiled"; opts = "sandbox=:big"),
            "test/broken_test.jl" => "@testitem \"broken\" begin\n",
            "test/TestItems.toml" => "[profiles.big]\nthreads = \"1\"\n",
        )
        r = list_items(dir)
        @test r.root == dir
        @test r.failed == String[]          # no run recorded yet
        byname = Dict(it.name => it for it in r.items)
        @test sort(collect(keys(byname))) == ["alone", "chained", "first", "profiled", "second"]
        first_ = byname["first"]
        @test first_.file == joinpath(dir, "test", "a_test.jl")
        # An item's lines run to the one before the next item, or to the end of the file.
        @test (first_.line, first_.end_line) == (1, byname["second"].line - 1)
        @test byname["chained"].end_line == countlines(first_.file)
        s = byname["second"]
        @test (s.tags, s.timeout, s.retries, s.skip, s.failfast) == (["fast", "db"], 30, 2, "1 == 2", nothing)
        @test (first_.tags, first_.timeout, first_.retries, first_.skip) == (String[], nothing, nothing, false)
        @test (byname["chained"].chain, byname["chained"].failfast) == ("c", true)
        @test (byname["alone"].sandbox, byname["alone"].profile) == (true, nothing)
        @test (byname["profiled"].sandbox, byname["profiled"].profile) == (true, "big")
        # The broken file is an error beside the items of the files that read.
        @test only(r.errors).file == joinpath(dir, "test", "broken_test.jl")

        # A name used twice, and settings that do not read, are errors too.
        dup = make_pkg("Dup", "test/a_test.jl" => item("same") * item("same"),
                       "test/TestItems.toml" => "[run]\nworkerz = 2\n")
        errs = list_items(dup).errors
        @test any(e -> occursin("duplicate test item name", e.message), errs)
        @test any(e -> e.file == joinpath(dup, "test", "TestItems.toml") && occursin("workerz", e.message), errs)
        @test length(list_items(dup).items) == 2
    end

    @testset "a session: list, run what was asked for, say what happened, answer every mistake" begin
        dir = make_pkg(
            "Served",
            "test/a_test.jl" => string(
                item("passes"), item("fails", "x = 1\n    @test x == 2"), item("not asked for"),
                item("flaky", "m = joinpath(ENV[\"SERVED_DIR\"], \"flaky\")\n    first = !isfile(m)\n" *
                              "    first && touch(m)\n    @test !first"; opts = "retries=1"),
            ),
        )
        marker = mktempdir()
        with_runstate_dir() do _
            withenv("SERVED_DIR" => marker) do
                s = open_session(dir)
                hello = next_event(s)
                @test hello["event"] == "hello" && hello["protocol"] == PROTOCOL_VERSION && hello["root"] == dir

                send(s, (; id = 1, command = "list"))
                items = next_event(s)
                @test items["event"] == "items" && items["id"] == 1
                @test length(items["items"]) == 4 && isempty(items["errors"])

                send(s, (; id = "r", command = "run", names = ["passes", "fails", "flaky", "no such item"],
                         options = (; workers = 1)))
                seen = events_until(e -> e["event"] == "run_finished", s)
                started = only(e for e in seen if e["event"] == "run_started")
                @test started["id"] == "r"
                @test sort(started["items"]) == ["fails", "flaky", "passes"]
                @test started["unknown"] == ["no such item"]
                @test started["workers"] == 1 && startswith(started["seed"], "0x")
                @test all(e -> e["id"] == "r", seen)
                finished = [e for e in seen if e["event"] == "item_finished"]
                ends(name) = [e for e in finished if e["name"] == name]
                @test only(ends("passes"))["state"] == "passed"
                # A failure says where it is and what it was.
                f = only(ends("fails"))
                @test f["state"] == "failed" && f["attempts"] == 1
                failure = only(f["failures"])
                @test failure["kind"] == "fail"
                @test failure["file"] == joinpath(dir, "test", "a_test.jl")
                @test failure["line"] == 6
                @test occursin("x == 2", failure["message"])
                @test f["elapsed"] > 0 && f["pid"] > 0 && f["worker"] == 1
                # Each attempt is said, the last one standing.
                @test [(e["attempt"], e["state"]) for e in ends("flaky")] == [(1, "failed"), (2, "passed")]
                @test count(e -> e["event"] == "item_started" && e["name"] == "flaky", seen) == 2
                done = last(seen)
                @test done["state"] == "failed"
                @test done["counts"]["passed"] == 2 && done["counts"]["failed"] == 1
                @test isempty(done["not_run"])
                @test isfile(done["runstate"])
                @test isdir(done["logdir"])        # kept for the editor until the next run
                # What the newest run did not pass, for an editor's "run failed".
                send(s, (; id = 2, command = "list"))
                @test next_event(s)["failed"] == ["fails"]

                # Every mistake is answered, and the session goes on.
                for (bad, says) in (
                        "not json" => "malformed JSON", "[1]" => "a command is a JSON object",
                        "{\"command\": \"frob\"}" => "unknown command",
                        json((; command = "run", names = "passes")) => "`names` is a list",
                        json((; command = "run", options = (; bogus = 1))) => "unknown option \"bogus\"",
                        json((; command = "run", options = (; workers = -3))) => "workers",
                        json((; command = "run", names = ["no such item"])) => "no test items matched",
                        json((; command = "cancel")) => "no run in progress",
                    )
                    send(s, bad)
                    e = next_event(s)
                    @test e["event"] == "error"
                    @test occursin(says, e["message"])
                end

                # One run at a time.
                send(s, (; id = 7, command = "run", names = ["passes"], options = (; workers = 1)))
                send(s, (; id = 8, command = "run", names = ["passes"]))
                seen = events_until(e -> e["event"] == "run_finished", s)
                busy = only(e for e in seen if e["event"] == "error")
                @test busy["id"] == 8 && occursin("already in progress", busy["message"])
                @test last(seen)["id"] == 7 && last(seen)["state"] == "passed"
                # A run of another item leaves the failure as it was.
                send(s, (; id = 9, command = "list"))
                @test next_event(s)["failed"] == ["fails"]
                @test !isdir(done["logdir"])        # the earlier run's logs went with it

                close_session(s)
                @test last(collect(s.events))["event"] == "bye"
            end
        end
    end

    @testset "a session reads the config file it was started with, to list and to run" begin
        dir = make_pkg("ServedConfig", "test/a_test.jl" => string(item("plain"), item("fast"; opts = "sandbox=:fast")))
        config = joinpath(mktempdir(), "editor.toml")
        write(config, "[run]\nworkers = 1\n[profiles.fast]\nthreads = \"1\"\n")
        with_runstate_dir() do _
            # Without it, the profile the item names is unknown, and said to be.
            s = open_session(dir)
            @test next_event(s)["config"] === nothing
            send(s, (; id = 1, command = "list"))
            errors = next_event(s)["errors"]
            @test length(errors) == 1 && occursin("[profiles.fast]", only(errors)["message"])
            @test only(errors)["file"] == joinpath(dir, "test", "TestItems.toml")
            close_session(s)
            # With it: said in `hello`, read for the listing, and for the run.
            s = open_session(dir; config)
            @test next_event(s)["config"] == config
            send(s, (; id = 1, command = "list"))
            @test isempty(next_event(s)["errors"])
            send(s, (; id = 2, command = "run", names = ["plain"]))
            seen = events_until(e -> e["event"] == "run_finished", s)
            @test only(e for e in seen if e["event"] == "run_started")["workers"] == 1
            @test last(seen)["state"] == "passed"
            close_session(s)
            # A file that is not there is a problem the listing names.
            s = open_session(dir; config = joinpath(dirname(config), "gone.toml"))
            next_event(s)
            send(s, (; id = 1, command = "list"))
            errors = next_event(s)["errors"]
            @test length(errors) == 1 && occursin("gone.toml does not exist", only(errors)["message"])
            @test only(errors)["file"] == joinpath(dirname(config), "gone.toml")
            close_session(s)
        end
    end

    @testset "a cancel stops the run at once and takes its workers with it" begin
        dir = make_pkg("Cancelled", "test/a_test.jl" => join((item("slow $i", "sleep(600)") for i in 1:3)))
        with_runstate_dir() do _
            s = open_session(dir)
            next_event(s)
            send(s, (; id = 1, command = "run", options = (; workers = 2)))
            events_until(e -> e["event"] == "item_started", s)
            pids = live_worker_pids()
            t = @elapsed begin
                send(s, (; id = 2, command = "cancel"))
                seen = events_until(e -> e["event"] == "run_finished", s)
            end
            done = last(seen)
            @test done["id"] == 1 && done["state"] == "cancelled"
            @test t < 30
            @test !isempty(done["not_run"]) || done["counts"]["cancelled"] > 0
            Sys.iswindows() || @test all_gone(pids)
            # The session is still there for the next command.
            send(s, (; id = 3, command = "list"))
            @test next_event(s)["event"] == "items"
            close_session(s)
        end
    end

    @testset "over its own stdout, a server writes events and nothing else" begin
        # What an editor sees: a process of its own, whose items print and log, and
        # whose stdout still carries only JSON.
        dir = make_pkg("Streamed", "test/a_test.jl" => item("talks", "println(\"from the item\")\n    @info \"logged\"\n    @test true") *
                                                       item("fails", "@test false"))
        root = dirname(@__DIR__)
        cmd = setenv(`$(Base.julia_cmd()) --project=$root --startup-file=no -e "using Runtests; Runtests.serve(ARGS[1])" $dir`,
                     "JULIA_LOAD_PATH" => join([root, joinpath(root, "test"), ""], Sys.iswindows() ? ';' : ':'),
                     "RUNTESTS_RUNSTATE_DIR" => mktempdir())
        err = Base.BufferStream()
        proc = open(pipeline(cmd; stderr = err), "r+")
        lines = String[]
        function upto(event)
            while true
                line = readline(proc)
                isempty(line) && eof(proc) && error("the server ended before `$event`; its stderr:\n", String(readavailable(err)))
                push!(lines, line)
                read_json(line)["event"] == event && return
            end
        end
        upto("hello")
        println(proc, json((; id = 1, command = "run", options = (; workers = 1, logs = "eager"))))
        upto("run_finished")
        close(proc.in)          # the end of its input ends the session
        upto("bye")
        wait(proc)
        close(err)
        # Every line of stdout is an event; what the run printed went to stderr.
        @test all(l -> read_json(l) isa Dict, lines)
        human = read(err, String)
        @test occursin("from the item", human)
        @test occursin("ran 2 test items", human)
        @test success(proc)
    end
end
