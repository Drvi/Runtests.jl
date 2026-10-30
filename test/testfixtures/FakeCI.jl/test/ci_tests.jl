# A suite whose run on CI is checked rather than trusted: each item ends in a known
# way and leaves known evidence, which `.github/scripts/verify_fake_run.jl` reads back
# from what the CI job uploaded. Changing an item here means changing what it expects.

@testitem "passes" begin
    import Runtests
    # Written, and deleted when the attempt passes; the producer never runs.
    write(joinpath(Runtests.artifacts_dir(), "unused.txt"), "deleted when the attempt passes")
    Runtests.on_failure(dir -> write(joinpath(dir, "never.txt"), "never"))
    @test FakeCI.double(2) == 4
end

@testitem "fails an assertion" begin
    import Runtests
    println("printed by the failing item")
    # Drawn from the item's seed, so a replay draws the same number.
    write(joinpath(Runtests.artifacts_dir(), "drawn.txt"), string(rand(UInt64)))
    expected = 42
    Runtests.on_failure() do dir
        write(joinpath(dir, "report.txt"), "expected $expected, got $(FakeCI.double(20))")
    end
    @test FakeCI.double(20) == expected
end

@testitem "throws" begin
    import Runtests
    Runtests.on_failure(dir -> write(joinpath(dir, "state.txt"), "collected after an error"))
    error("thrown on purpose")
end

@testitem "producers that misbehave" begin
    import Runtests
    Runtests.on_failure(dir -> error("a producer that throws"))
    Runtests.on_failure(dir -> write(joinpath(dir, "ok.txt"), "the next producer still runs"))
    @test false
end

@testitem "passes on a retry" retries=1 begin
    import Runtests
    attempt = Runtests.current_testitem().attempt
    write(joinpath(Runtests.artifacts_dir(), "attempt.txt"), string(attempt))
    Runtests.on_failure(dir -> write(joinpath(dir, "attempt.txt"), string(attempt)))
    @test attempt == 2
end

@testitem "times out" timeout=10 begin
    import Runtests
    write(joinpath(Runtests.artifacts_dir(), "before.txt"), "written before the hang")
    Runtests.on_failure(dir -> write(joinpath(dir, "never.txt"), "never"))
    sleep(600)
end

@testitem "kills its worker" begin
    import Runtests
    write(joinpath(Runtests.artifacts_dir(), "before.txt"), "written before the exit")
    Runtests.on_failure(dir -> write(joinpath(dir, "never.txt"), "never"))
    exit(3)
end

@testitem "hangs in a producer" begin
    import Runtests
    Runtests.on_failure() do dir
        write(joinpath(dir, "partial.txt"), "written before the hang")
        sleep(600)
    end
    @test false
end

@testitem "skipped" skip=true begin
    @test false
end

@testitem "broken" begin
    @test_broken false
end
