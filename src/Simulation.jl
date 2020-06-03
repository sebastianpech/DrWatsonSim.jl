export simdir, simid, @run, in_simulation_mode

const ENV_SIM_FOLDER = "SIMULATION_FOLDER"
const ENV_SIM_ID = "SIMULATION_ID"

from_folder_name(n::String) = parse(Int, n) 
to_folder_name(n) = string(n)
in_simulation_mode() = ENV_SIM_ID in keys(ENV)

function simdir(args...)
    if ENV_SIM_FOLDER in keys(ENV)
        return joinpath(ENV[ENV_SIM_FOLDER],args...)
    end
    error("Not in simulation environment")
end

function simid()
    if ENV_SIM_ID in keys(ENV)
        return parse(Int,ENV[ENV_SIM_ID])
    end
    error("Not in simulation environment")
end

function get_next_simulation_id(folder)
    id = 1
    for i in 1:100_000_000
        try
            mkdir(joinpath(folder,to_folder_name(id)))
            return id
        catch e
            if e.code != -17
                rethrow(e)
            end
            id += 1
        end
    end
    error("Couldn't genereate new id in '$folder'")
end

run_simulation(f,p,args...) = run_simulation(f, [p], args...)

function run_simulation(f,param,directory,source)
    @sync for p in param
        if in_simulation_mode()
            m = Metadata(simdir())
            @assert m["simulation_id"] == simid()
            f(m["parameters"])
            return
        end
        id = get_next_simulation_id(directory)
        folder = joinpath(directory,to_folder_name(id))
        m = Metadata(folder)
        tag!(m.data, source=source)
        save_metadata(m)
        julia = Base.julia_cmd()
        env = copy(ENV)
        m["simulation_id"] = id
        m["parameters"] = p
        m["mtime_scriptfile"] = mtime(PROGRAM_FILE)
        m["julia_command"] = julia
        m["ENV"] = env
        env[ENV_SIM_FOLDER] = folder
        env[ENV_SIM_ID] = string(id)
        @async run(detach(setenv(`$julia $(PROGRAM_FILE)`, env)))
    end
end

macro run(f, p, directory)
    source=QuoteNode(__source__)
    :(run_simulation($(esc(f)), $(esc(p)), $(esc(directory)), $source))
end
