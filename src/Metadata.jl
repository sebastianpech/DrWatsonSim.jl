export Metadata, Metadata!, rename!, delete!

import Base.==

const metadata_folder_name = ".metadata"
const max_lock_retries = 100
const metadata_lock = "metadata.lck"

metadatadir(args...) = projectdir(metadata_folder_name, args...)

mutable struct Metadata <: AbstractDict{String, Any}
    path::String
    mtime::Float64
    data::Dict{String,Any}
end

function Metadata(path::String; overwrite=false)
    (isfile(path) || isdir(path)) || @warn "There is no file or folder at '$path'."
    assert_metadata_directory()
    rel_path = project_rel_path(path)
    # Check if there is already an entry for that file in the index
    lock("metadata")
    semaphore_enter("indexread")
    unlock("metadata")
    _path = find_file_in_index(path)
    semaphore_exit("indexread")
    if _path != nothing && !overwrite
        m = load_metadata(_path)
        if m.mtime != mtime(path) && isfile(path)
            @warn "The metadata entries might not be up to date. The file changed after adding the entries"
        end
    elseif _path != nothing && overwrite
        m = Metadata(rel_path, mtime(path), Dict{String,Any}())
        save_metadata(m)
    else
        lock("metadata", wait_for_semaphore="indexread")
        try
            m = Metadata(rel_path, mtime(path), Dict{String,Any}())
            save_metadata(m)
        finally
            unlock("metadata")
        end
    end
    return m
end

Base.length(m::Metadata) = length(m.data)
Base.iterate(m::Metadata, args...; kwargs...) = iterate(m.data, args...; kwargs...)

Metadata!(path::String) = Metadata(path, overwrite=true)

project_rel_path(path) = relpath(abspath(path), projectdir())
get_stored_path(m::Metadata) = getfield(m,:path)

standardize_path(path) = join(splitpath(project_rel_path(path)), "/")
hash_path(path) = hash(standardize_path(path))
to_file_name(x) = string(x)*".bson"

function load_metadata(path; ignore_exceptions=false)
    try
        entry = BSON.load(path)
        Metadata([entry[string(field)] for field in fieldnames(Metadata)]...)
    catch e
        if ignore_exceptions
            return nothing
        else
            rethrow(e)
        end
    end
end

function find_file_in_index(path)
    file = metadatadir(hash_path(path)|>to_file_name)
    isfile(file) && return file
    return nothing
end

function ==(a::Metadata,b::Metadata)
    for k ∈ fieldnames(Metadata)
        if getfield(a,k) != getfield(b,k)
            return false
        end
    end
    return true
end

Base.setproperty!(m::Metadata, sym::Symbol, val) = error("The field '$sym' is treated as immutable and cannot be updated directly.")
Base.getproperty(m::Metadata, sym::Symbol) = getproperty(m, Val(sym))
getproperty(m::Metadata, ::Val{T}) where T = getfield(m, T)
getproperty(m::Metadata, ::Val{:path}) = projectdir(getfield(m, :path))

Base.getindex(m::Metadata, field::String) = m.data[field]
function Base.setindex!(m::Metadata, val, field::String)
    m.data[field] = val
    save_metadata(m)
    return val
end

Base.keys(m::Metadata) = keys(m.data)
function Base.delete!(m::Metadata, field)
    delete!(m.data,field)
    save_metadata(m)
    return m
end

function rename!(m::Metadata, path)
    rel_path = project_rel_path(path)
    assert_metadata_directory()
    lock("metadata", wait_for_semaphore="indexread")
    try
        if find_file_in_index(rel_path) != nothing 
            unlock("metadata")
            error("There is already metadata stored for '$path'.")
        end
        new_metadata_file = metadatadir(hash_path(path)|>to_file_name)
        old_metadata_file = metadatadir(hash_path(m.path)|>to_file_name)
        mv(old_metadata_file, new_metadata_file)
        setfield!(m, :path, rel_path)
        save_metadata(m)
    finally
        unlock("metadata")
    end
end

function Base.delete!(m::Metadata)
    assert_metadata_directory()
    lock("metadata", wait_for_semaphore="indexread")
    try
        file = metadatadir(to_file_name(hash_path(m.path)))
        if !isfile(file)
            unlock("metadata")
            error("There is no metadata storage for id $(m.path)")
        end
        rm(file)
        remove_index_entry(m.id, get_stored_path(m))
    finally
        unlock("metadata")
    end
end

function save_metadata(m::Metadata)
    setfield!(m,:mtime,mtime(m.path))
    BSON.bson(metadatadir(to_file_name(hash_path(m.path))),Dict(string(field)=>getfield(m,field) for field in fieldnames(Metadata)))
end

function assert_metadata_directory()
    metadata_directory = metadatadir()
    if !isdir(metadata_directory)
        @info "Metadata directory not found, creating a new one"
        try
            mkdir(metadata_directory)
        catch e
            if !isa(e, Base.IOError)
                rethrow(e)
            end
        end
    end
end

function DrWatson.tag!(m, args...; kwargs...)
    tag!(m.data, args...; kwargs...)
    save_metadata(m)
end
