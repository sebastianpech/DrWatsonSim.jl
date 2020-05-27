export simdir, @run

const ENV_FOLDER = "SIMULATION_FOLDER"
const ENV_METADATA = "SIMULATION_METADATA_ID"

from_folder_name(n::String) = parse(Int, n) 
to_folder_name(n) = string(n)

function simdir(args...)
    if ENV_FOLDER in keys(ENV)
        return joinpath(ENV[ENV_FOLDER],args...)
    end
    error("Not in simulation environment")
end

run_simulation(f,p,args...) = run_simulation(f, [p], args...)

function run_simulation(f,param,directory,source)
    @sync for p in param
        if ENV_METADATA in keys(ENV)
            m = Metadata(parse(Int,ENV[ENV_METADATA]))
            f(m["parameters"])
            return
        end
        id = reserve_next_identifier()
        foldername = to_folder_name(id)
        mkdir(joinpath(directory,foldername))
        m = Metadata(id, joinpath(directory,foldername))
        tag!(m.data, source=source)
        save_metadata(m)
        m["parameters"] = p
        env = copy(ENV)
        env[ENV_FOLDER] = joinpath(directory,foldername)
        env[ENV_METADATA] = string(m.id)
        julia = Base.julia_cmd()
        @async run(detach(setenv(`$julia $(PROGRAM_FILE)`, env)))
    end
end

macro run(f, p, directory)
    source=QuoteNode(__source__)
    :(run_simulation($(esc(f)), $(esc(p)), $(esc(directory)), $source))
end
