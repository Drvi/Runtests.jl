module Faulty
marker(name) = joinpath(get(ENV, "RUNTESTS_FAULTY_DIR", tempdir()), "runtests_" * name)
end
