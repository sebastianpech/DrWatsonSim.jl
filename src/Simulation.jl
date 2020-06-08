export simdir, simid, @run, @runsync, @rerun, @rerunsync, in_simulation_mode

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
            if !isa(e, Base.IOError)
                rethrow(e)
            end
            id += 1
        end
    end
    error("Couldn't genereate new id in '$folder'")
end

run_simulation(f,p,args...) = run_simulation(f, [p], args...)

function run_in_simulation_mode(f)
    m = Metadata(simdir())
    @assert m["simulation_id"] == simid()
    f(m["parameters"])
end

function run_simulation(f,param,directory,source; wait_for_finish=false)
    simulation_submit_time = DrWatsonSim.now()
    if in_simulation_mode()
        run_in_simulation_mode(f)
    else
        simulation_ids = map(param) do _
            get_next_simulation_id(directory)
        end
        tasks = map(zip(param,simulation_ids)) do (p,id)
            folder = joinpath(directory,to_folder_name(id))
            m = Metadata(folder)
            tag!(m.data, source=source)
            save_metadata(m)
            julia = Base.julia_cmd()
            env = copy(ENV)
            m["simulation_submit_time"] = simulation_submit_time
            m["simulation_submit_group"] = [standardize_path(joinpath(directory,to_folder_name(i))) for i in simulation_ids]
            m["simulation_id"] = id
            m["parameters"] = p
            m["mtime_scriptfile"] = mtime(PROGRAM_FILE)
            m["julia_command"] = julia
            m["ENV"] = env
            env[ENV_SIM_FOLDER] = folder
            env[ENV_SIM_ID] = string(id)
            return @async run(setenv(`$julia $(PROGRAM_FILE)`, env), wait=wait_for_finish)
        end
        !in_simulation_mode() && wait.(tasks)
    end
end

function rerun_simulation(f,folder,source; wait_for_finish=false)
    if in_simulation_mode()
        run_in_simulation_mode(f)
    else
        m_original = Metadata(folder)
        p = m_original["parameters"]
        id = m_original["simulation_id"]
        simulation_submit_group = m_original["simulation_submit_group"]
        m = Metadata!(folder)
        tag!(m.data, source=source)
        save_metadata(m)
        julia = Base.julia_cmd()
        env = copy(ENV)
        m["simulation_submit_time"] = DrWatsonSim.now()
        m["simulation_submit_group"] = simulation_submit_group
        m["simulation_id"] = id
        m["parameters"] = p
        m["mtime_scriptfile"] = mtime(PROGRAM_FILE)
        m["julia_command"] = julia
        m["ENV"] = env
        env[ENV_SIM_FOLDER] = folder
        env[ENV_SIM_ID] = string(id)
        t = @async run(setenv(`$julia $(PROGRAM_FILE)`, env), wait=wait_for_finish)
        wait(t)
    end
end

macro run(f, p, directory)
    source=QuoteNode(__source__)
    :(run_simulation($(esc(f)), $(esc(p)), $(esc(directory)), $source))
end

macro runsync(f, p, directory)
    source=QuoteNode(__source__)
    :(run_simulation($(esc(f)), $(esc(p)), $(esc(directory)), $source, wait_for_finish=true))
end

macro rerun(f, path)
    source=QuoteNode(__source__)
    :(rerun_simulation($(esc(f)), $(esc(path)), $source))
end

macro rerunsync(f, path)
    source=QuoteNode(__source__)
    :(rerun_simulation($(esc(f)), $(esc(path)), $source, wait_for_finish=true))
end


