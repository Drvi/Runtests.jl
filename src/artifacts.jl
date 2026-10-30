# The evidence of attempts that failed, as the coordinator keeps it: where each
# attempt's goes, what is kept, and running the producers of one that failed. The side
# test code calls, `Runtests.on_failure` and `Runtests.artifacts_dir`, is in
# RuntestsWorkers.

"""
    artifacts_path(prefix, index, attempt) -> String

Where attempt `attempt` at item `index` keeps its evidence: `item_<index>_<attempt>.artifacts`,
beside its log, with `prefix` the part of the path a log's shares.
"""
artifacts_path(prefix::String, index::Integer, attempt::Integer) =
    string(chopsuffix(item_log_path(prefix, index, attempt), ".log"), ".artifacts")

attempt_artifacts(run::Run, i::Integer, attempt::Integer) = artifacts_path(run.artifacts_prefix, i, attempt)

# A line in the log beside the evidence in `dir`, as a person reads it. Never a reason
# to fail: the verdict is recorded already, and the evidence is what it is.
function note_evidence(dir::AbstractString, text::AbstractString)
    try
        open(io -> println(io, text), artifacts_log_path(dir), "a")
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not write to $(artifacts_log_path(dir))" exception = e
    end
    return nothing
end

# What an attempt that passed left: deleted, as nothing will read it.
function discard_evidence(dir::AbstractString)
    try
        rm(dir; force = true, recursive = true)
        rm(artifacts_log_path(dir); force = true)
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not delete $(dir), which an attempt that passed wrote" exception = e
    end
    return nothing
end

# An attempt whose evidence is kept, for the closing report.
keep_evidence!(run::Run, i::ItemIdx, attempt::Int8) = (@lock run.lock push!(run.evidence, (i, attempt)); nothing)

"""
    evidence_after_loss!(run, i, attempt, why) -> UInt8

What is kept of the evidence of an attempt whose worker did not survive it, or that
did not report its result: what it wrote, and word, when it registered producers,
that they did not run and `why`. Returns what the attempt left, as a result says it.
"""
function evidence_after_loss!(run::Run, i::ItemIdx, attempt::Int8, why::AbstractString)
    dir = attempt_artifacts(run, i, attempt)
    flags = (isdir(dir) ? ARTIFACT_FILES : 0x00) | (isfile(artifacts_log_path(dir)) ? ARTIFACT_PRODUCERS : 0x00)
    flags == 0 && return flags
    flags & ARTIFACT_PRODUCERS == 0 ||
        note_evidence(dir, string("not collected: ", why, ", so the producers did not run; what the attempt wrote is kept"))
    keep_evidence!(run, i, attempt)
    return flags
end

"""
    finish_attempt!(run, slot, i, attempt, res, w) -> Bool

What follows the recorded verdict `res` of attempt `attempt` at item `i`, on worker
`w`, or in this process when `w` is `nothing`: what an attempt that passed wrote is
deleted, and its producers let go of when the worker runs its next item; what one
that failed wrote is kept, and its producers run, within `artifacts_timeout` on a
worker. Returns whether the worker is still fit to use: one that does not finish in
time is ended, and one that dies is gone.
"""
function finish_attempt!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, res::ItemResult,
                         w::Union{Nothing, RuntestsWorkers.Worker})
    res.artifacts == 0 && return true
    dir = attempt_artifacts(run, i, attempt)
    if res.state === PASSED
        discard_evidence(dir)
        w === nothing && res.artifacts & ARTIFACT_PRODUCERS != 0 && RuntestsWorkers.discard_artifacts!()
        return true
    end
    keep_evidence!(run, i, attempt)
    res.artifacts & ARTIFACT_PRODUCERS == 0 && return true
    name = run.plan.items.name[i]
    limit = run.plan.cfg.artifacts_timeout_s
    survived = true
    said = ""
    @atomic slot.collecting = i
    try
        status = if w === nothing
            RuntestsWorkers.finish_artifacts(i, attempt, true)
        else
            fetch_within(RuntestsWorkers.remote_finish(w, i, attempt, true), limit,
                         TimeoutException(limit, "collecting the artifacts of", name, "artifacts_timeout"))
        end
        said = string(plural(status.producers, "producer"), status.failed == 0 ? "" : string(", ", status.failed, " failed"),
                      " in ", fmt_seconds(status.seconds))
    catch e
        if is_interrupt(e)
            shielded(() -> note_evidence(dir, "incomplete: the run was stopped while the producers ran; what they wrote is kept"))
            rethrow()
        end
        survived, said = collection_failed!(run, slot, i, attempt, e, w)
    finally
        @atomic slot.collecting = ItemIdx(0)
        # Progress, for the stall watchdog: the next attempt on this slot gets its own time.
        @atomic run.last_finish = time()
    end
    say(run, "artifacts of ", repr(name), attempt > 1 ? " (attempt $attempt)" : "", ": ", said, " · ", dir)
    return survived
end

# A collection that did not complete: why, in the log beside the evidence, and whether
# the worker survived it, with what the run is told.
function collection_failed!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, e, w)
    dir = attempt_artifacts(run, i, attempt)
    if w === nothing || !(e isa TimeoutException || w.terminated)
        # The worker is fine: the log could not be written, nothing was waiting, or
        # the reply did not read.
        msg = e isa RuntestsWorkers.RemoteException ? e.msg : sprint(showerror, e)
        note_evidence(dir, string("not collected: ", msg))
        return true, string("not collected: ", first(split(msg, '\n')))
    end
    if e isa TimeoutException
        print_worker_line(run, slot.id, "KILL", string("pid ", w.pid, " · ", sprint(showerror, e)))
        RuntestsWorkers.inspect!(w)
        # What the worker says on its way down goes beside the evidence, as an item's
        # dying words go in its log.
        @atomic slot.dying_log = artifacts_log_path(dir)
        RuntestsWorkers.terminate!(w, :timeout)
        wait(w)
        flush_dying_log!(slot)
        why = string("incomplete: ", sprint(showerror, e), "; the worker was ended, and what the producers wrote is kept")
    else
        wait(w)
        stopped = is_cancelled(run.queues) || w.ended_by === :interrupt
        why = stopped ? "incomplete: the run was stopped while the producers ran; what they wrote is kept" :
            string("incomplete: the worker died while the producers ran, ", died_how(run, slot, w),
                   "; what they wrote is kept")
    end
    (@atomic slot.worker) === w && (@atomic slot.worker = nothing)
    note_evidence(dir, why)
    return false, why
end

"""
    finish_here!(spec, res; worker, limit) -> String

What follows the result `res` of an attempt that ran outside a run: a pasted item, in
this process or on the `worker` of its sandbox, or one stepped through with `debug`.
What passed is deleted; what failed is kept and its producers run, on the worker
within `limit` seconds, after which it is ended. Returns where the evidence is, or
`""` when none is kept.
"""
function finish_here!(spec::ItemSpec, res::ItemResult; worker::Union{Nothing, RuntestsWorkers.Worker} = nothing,
                      limit::Integer = 0)
    res.artifacts == 0 && return ""
    if res.state === PASSED
        worker === nothing && res.artifacts & ARTIFACT_PRODUCERS != 0 && RuntestsWorkers.discard_artifacts!()
        discard_evidence(spec.artifacts)
        remove_if_empty(dirname(spec.artifacts))
        return ""
    end
    if res.artifacts & ARTIFACT_PRODUCERS != 0
        try
            if worker === nothing
                RuntestsWorkers.finish_artifacts(spec.index, spec.attempt, true)
            else
                fetch_within(RuntestsWorkers.remote_finish(worker, spec.index, spec.attempt, true), limit,
                             TimeoutException(limit, "collecting the artifacts of", spec.name, "artifacts_timeout"))
            end
        catch e
            is_interrupt(e) && (note_evidence(spec.artifacts, "incomplete: interrupted while the producers ran"); rethrow())
            worker === nothing || e isa TimeoutException && RuntestsWorkers.terminate!(worker, :timeout)
            note_evidence(spec.artifacts, string("incomplete: ", sprint(showerror, e), "; what the producers wrote is kept"))
        end
    end
    return spec.artifacts
end

# A directory of a run's or an item's own that nothing ended up in.
function remove_if_empty(dir::AbstractString)
    try
        isdir(dir) && isempty(readdir(dir)) && rm(dir)
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

# Where a pasted item, or one a debugger steps through, keeps its attempts' evidence:
# a directory of its own in the system's temporary files, made only if an attempt
# asks, and left there for whoever reads it to delete.
interactive_artifacts_prefix() =
    joinpath(tempdir(), string("runtests_artifacts_", string(rand(RandomDevice(), UInt64); base = 36)), "item_")

# Said once an attempt outside a run is over, where its evidence is.
function print_evidence(dir::AbstractString)
    isempty(dir) && return nothing
    println(stdout, label_prefix(), "artifacts: ", dir, isfile(artifacts_log_path(dir)) ? string(" · ", artifacts_log_path(dir)) : "")
    flush(stdout)
    return nothing
end
