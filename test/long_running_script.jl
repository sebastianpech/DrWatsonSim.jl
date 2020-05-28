using DrWatson
@quickactivate "dummy_project"
using DrWatsonSim
using BSON
using Dates

function long_running_computation(p,output_path)
    sleep(p[:duration])
    result = p[:a]^p[:b]
    BSON.bson(output_path, Dict(:result=>result))
    return nothing
end

duration = [2, 0.1, 1]
a = [1,2,3]
b = 1
parameter = @dict duration a b

if in_simulation_mode()
    # Using simid() here is actually better, because then the 
    # no lookup it the index file is need which means, that the 
    # database must not be loked.
    m = Metadata(simdir())
    println("$(simid()): Loaded metadata file")
    m["type"] = "Simple Computation"
    m["started at"] = Dates.now()
    println("$(simid()): Creating new files")
    m_new = Metadata(simdir("newfile"))
    m_new["extra"] = "This should be blocked"
    println("$(simid()): Done creating new file")
end

@run x->long_running_computation(x, simdir("output.bson")) dict_list(parameter) datadir("sims")
