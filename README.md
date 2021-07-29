# DrWatsonSim

[![Build Status](https://travis-ci.com/sebastianpech/DrWatsonSim.jl.svg?branch=master)](https://travis-ci.com/sebastianpech/DrWatsonSim.jl)

## Installation

The package relies heavily on `DrWatson`, so the sensible method for using `DrWatsonSim` is

1. Create a `DrWatson` project with `initialize_project`
2. `add DrWatsonSim` as a dependency

Upon first use of any metadata related function, a directory `projectdir(".metadata")` for storing the additional data is initialized.

## Adding Metadata

Metadata functions are centered around files (or folders) in the `DrWatson` project. 
Paths are always stored relative to `projectdir()`.
Adding data to a file is as simple as:

```julia
# Some parameters
a = 10
b = 12

# Creating or loading the metadata entry for the file
m = Metadata(datadir("somefile"))

# Tagging with git info
@tag! m

# Adding some info about the used parameters
m["parameters"] = @dict a b
```

This gives the following entry:

```
Metadata with 4 entries:
  "parameters" => Dict(:a=>10,:b=>12)
  "gitcommit"  => "fbb09d2ee3c5711ff559c296c0033b7331679871_dirty"
  "script"     => "scripts/REPL[9]#1"
  "gitpatch"   => ""
```

There is no need for an additional call to actually save the metadata, it's done automatically on every change.

The data can be retrieved using the same call as during creating eg. `Metadata(datadir("somefile"))`. 
Besides the `path`, the `mtime` of the files is used for recognition.
If the current `mtime` is newer than the stored one, `DrWatsonSim` issues a warning, that the metadata might not reflect the actual file content.

There is an additional method `Metadata!` that overwrites any existing entry for the given path.

## Running Simulations

The following example is taken from the [DrWatson workflow tutorial](https://juliadynamics.github.io/DrWatson.jl/dev/workflow/).
Instead of calling `makesim` from a loop over all parameters, the macro `@run` is used.
Also to justify usage of the simulation methods, the `makesim` function now writes data to a folder.

```julia
using DrWatson
@quickactivate
using DrWatsonSim
using FileIO

function fakesim(a, b, v, method = "linear")
    if method == "linear"
        r = @. a + b * v
    elseif method == "cubic"
        r = @. a*b*v^3
    end
    y = sqrt(b)
    return r, y
end

function makesim(d::Dict)
    @unpack a, b, v, method = d
    r, y = fakesim(a, b, v, method)
    fulld = copy(d)
    fulld["r"] = r
    fulld["y"] = y
    save(simdir("output.jld2"),fulld)
end

allparams = Dict(
    :a => [1, 2], 
    :b => [3, 4],
    :v => [rand(5)], 
    :method => "linear",
)

dicts = dict_list(allparams)

@run makesim dicts datadir("sims")
```

`@run` calls `makesim` on all elements from `dicts` and provides `datadir("sims")` as an output folder. 
However, the actual call to `makesim` is done in new Julia processes, that matches the original call to the script above.
The distinction between the two modes, the initialization and the actual simulation is done using environmental variables.

The simulation id is generated based on the directory that is passed in the `@run` call.
It's the smallest possible positive integer for which no folder in the provided directory exists.

1. Run `julia script_from_above.jl`
2. Scan the provided folder for the next available simulation id and created the simulation directory (`simdir()`)
3. Metadata for the generated folder is written containing information about the calling environment and the parameters
4. For every parameter a new detached Julia process is spawned with the same calling configuration as in (1), except additional environmental variables are set containing the simulation id of this run.
5. With this variables set, the script now behaves differently. The function `simdir()` is now provided which gives the path to the assigned simulation directory (In the above configuration `simdir("output.jld2")` equal `datadir("sims",id,"output.jld2")`), and instead of looping over all configuration now the one configuration identified by the id runs by loading the associated metadata.

For adding additional metadata while in simulation mode, one can place eg. this

```julia
if in_simulation_mode()
    m = Metadata(simdir())
    m["extra"] = "Some more info here"
end
```

before the `@run` call

### Waiting for simulations

By default simulations run asynchronous, so the calling script doesn't wait for the simulations to finish.
In order to wait for the sub processes, one can use `@runsync` inplace of `@run`.

### Rerunning simulations

Sometimes it's necessary to rerun a simulation with the same parameters.
This can be done by using `@rerun` or its synchronous counterpart `@rerunsync`.
The only arguments needed, are the function and the simulation directory.
So to rerun the simulation in simulation folder 3 from the above script, one just replaces

```julia
@run makesim dicts datadir("sims")
```

with

```julia
@rerun makesim datadir("sims","3")
```

### Running simulations in custom simulation environments

DrWatsonSim allows implementation of custom simulation environments to run parameter configurations in.
This is done by subtyping `AbstractSimulationEnvironment`, which then allows a custom definition of the function `DrWatsonSim.submit_command(<:AbstractSimulationEnvironment, id, env)`.
The default environment is defined a singleton type and is configured to just use julia:
```julia
submit_command(::AbstractSimulationEnvironment,id,env) = `$(Base.julia_cmd()) $(PROGRAM_FILE)`
```

For running jobs using a custom scheduler command (eg. `qsub`) one can use the following code.
First define a new type. Here, additionally, the number of cpus must be defined, as they are required for the scheduler:
```julia
struct GridEngine <: DrWatsonSim.AbstractSimulationEnvironment
    cpus
end
```
Then define the actual command for submitting:
```julia
function DrWatsonSim.submit_command(conf::GridEngine, id, env)
    wd = env[DrWatsonSim.ENV_SIM_FOLDER] # Simulation folder is stored in environment variable
    log_out = joinpath(wd,"output.log")
    log_err = joinpath(wd,"error.log")
    `qsub -b y -cwd -q nodes.q -V -pe openmpi_fill $(conf.cpus) -N test-$(id) -o $(log_out) -e $(log_err) $(Base.julia_cmd()) $(PROGRAM_FILE)`
end
```

The only further change required, is defining which environment should be used during running the simulation.
This is done in the final run call:
```julia
@runsync GridEngine(4) f parameters datadir("sims")
```

Similarly, one can define a custom command for Slurm
```julia
function DrWatsonSim.submit_command(conf::Slurm, id, env)
    wd = env[DrWatsonSim.ENV_SIM_FOLDER]
    log_out = joinpath(wd,"output.log")
    cmd_str = string(`$(Base.julia_cmd()) $(PROGRAM_FILE)`)[2:end-1] # remove the backticks from command interpolation
    `sbatch --export=ALL --nodes=1 --ntasks=$(conf.cpus) --job-name=test-$(id) --time=720:00:00 --output=$(log_out) --wrap=$(cmd_str)`
end
```

### Metadata stored for simulations

| key                         | description                                                                                  |
|-----------------------------|----------------------------------------------------------------------------------------------|
| `"simulation_submit_time"`  | `Dates.now()` when `@run`, and others, were called                                           |
| `"simulation_submit_group"` | Project directory relative paths to simulation folders of jobs that were started in parallel |
| `"simulation_id"`           | Unique id of this simulation run. Is equal to the name of the simulation folder              |
| `"parameters"`              | Parameters for this simulation run ie. `p` in `f(p)`                                         |
| `"mtime_scriptfile"`        | `mtime` of the sending script file                                                           |
| `"julia_command"`           | Full julia command that was used for calling the script file                                 |
| `"ENV"`                     | Current environment variables                                                                |


## Retrieving Metadata

The function `get_metadata` is provided for faster and simpler querying of the metadata database:

- `get_metadata()` Return all stored entries
- `get_metadata(path::String)` Return the entry for `path`, if none found, search parent folders for data
- `get_metadata(f::Function)` Return all entries `m` for which `f(m) == true`
- `get_metadata(field::String,value)` Return all entries where `field` has the value `value`

## Design

Metadata is stored in a separated folder `.metadata` inside the project directory.
The filenames are generated based on a file path `p` as follows:

1. If `p` is a relative path, make it absolute using `abspath`, otherwise leave `p` as it is
2. Make `p` relative to the project directory (`projectdir()`). This way metadata can be retrieved independent of the location of the project directory.
3. Replace the file separators with `/`. This way metadata can be retrieved on any OS.
4. Use `hash` to generated the final metadata filename for `p`
