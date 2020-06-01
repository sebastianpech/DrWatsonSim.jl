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
Alternatively, the data can be loaded using eg. `Metadata(1)`.
The id is stored in the `id` field for `Metadata`.
Besides the `path` and the unique entry `id`, the `mtime` of the files is used for recognition.
If current `mtime` is newer than the stored one, `DrWatsonSim` issues a warning, that the metadata might not reflect the actual file content.

There is an additional method `Metadata!` that overwrites any existing entry for the given path.

## Running Simulations

The following example is taken from the [DrWatson workflow tutorial](https://juliadynamics.github.io/DrWatson.jl/dev/workflow/).
Instead of calling `makesim` from a loop over all parameters, the macro `@run` is used.
Also to justify usage of the simulation methods, the `makesim` function now writes data to a folder.

```julia
using DrWatson
@quickactivate
using DrWatsonSim
using BSON

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
    fulld[:r] = r
    fulld[:y] = y
    BSON.bson(simdir("output.bson"))
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

1. Run `julia script_from_above.jl`
2. Using the metadata functions, a new unique id is generated and simulation folder with this id is created in the output folder
3. Metadata for the generated id is written containing information about the calling environment and the parameters
4. For every parameter a new detached Julia process is spawned with the same calling configuration as in (1), except additional environmental variables are set containing metadata id of this run.
5. With this variables set, the script now behaves differently. The function `simdir()` is now provided which gives the path to the assigned simulation directory (In the above configuration `simdir("output.bson")` equal `datadir("sims",id,"output.bson")`), and instead of looping over all configuration now the one configuration identified by the metadata id runs.

For adding additional metadata while in simulation mode, one can place eg. this

```julia
if in_simulation_mode()
    m = Metadata(simid())
    m["extra"] = "Some more info here"
end
```

before the `@run` call

## Retrieving Metadata

The function `get_metadata` is provided for faster and simpler querying of the metadata database:

- `get_metadata()` Return all stored entries
- `get_metadata(path::String)` Return the entry for `path`, if none found, search parent folders for data
- `get_metadata(f::Function)` Return all entries `m` for which `f(m) == true`
- `get_metadata(field::String,value)` Return all entries where `field` has the value `value`

