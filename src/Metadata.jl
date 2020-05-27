export Metadata, Metadata!, rename!, delete!

const metadata_folder_name = ".metadata"
const metadata_lock = "metadata.lck"
const metadata_index = "index.bson"
const metadata_max_unlock_retries = 10
const metadata_sleep = 0.1

metadatadir(args...) = projectdir(metadata_folder_name, args...)
metadatalock() = metadatadir(metadata_lock)
metadataindex() = metadatadir(metadata_index)

mutable struct Metadata <: AbstractDict{String, Any}
    id::Int
    path::String
    mtime::Float64
    data::Dict{String,Any}
end

Base.length(m::Metadata) = length(m.data)
Base.iterate(m::Metadata, args...; kwargs...) = iterate(m.data, args...; kwargs...)

Metadata!(path::String) = Metadata(path, overwrite=true)

function Metadata(path::String; overwrite=false)
    assert_metadata_directory()
    lock_metadata_directory()
    rel_path = relpath(path, projectdir())
    # Check if there is already an entry for that file in the index
    _id = find_file_in_index(rel_path)
    if _id != nothing && !overwrite
        m = Metadata(_id)
        if m.mtime != mtime(path) && isfile(path)
            @warn "The metadata entries might not be up to date. The file changed after adding the entries"
        end
    elseif _id != nothing && overwrite
        m = Metadata(_id, rel_path, mtime(path), Dict{String,Any}())
        save_metadata(m)
    else
        m = Metadata(get_next_identifier(), rel_path, mtime(path), Dict{String,Any}())
        add_index_entry(m.id, m.path)
        save_metadata(m)
    end
    unlock_metadata_directory()
    return m
end

function Metadata(id::Int, path::String)
    assert_metadata_directory()
    lck_path = metadatadir(to_lck_file_name(id))
    rel_path = relpath(path, projectdir())
    lock_metadata_directory()
    if !isfile(lck_path) 
        unlock_metadata_directory()
        error("No locked metadata file with id '$id'")
    end
    if find_file_in_index(rel_path) != nothing 
        unlock_metadata_directory()
        error("There is already metadata stored for '$path'.")
    end
    m = Metadata(id, rel_path, mtime(rel_path), Dict{String, Any}())
    add_index_entry(m.id, m.path)
    save_metadata(m)
    unlock_metadata_directory()
    return m
end

function reserve_next_identifier()
    assert_metadata_directory()
    lock_metadata_directory()
    id = get_next_identifier()
    unlock_metadata_directory()
    return id
end

function add_index_entry(id::Int, path::String)
    index = BSON.load(metadataindex())
    index[id] = path
    BSON.bson(metadataindex(),index)
    return nothing
end

function remove_index_entry(id::Int)
    index = BSON.load(metadataindex())
    delete!(index,m.id)
    BSON.bson(metadataindex(),index)
    return nothing
end

function find_file_in_index(path)
    index = BSON.load(metadataindex())
    for id in keys(index)
        if index[id] == path 
            return id
        end
    end
end

function Metadata(id::Int)
    path = metadatadir(to_file_name(id))
    isfile(path) || error("No metadata entry for id '$id'")
    entry = BSON.load(metadatadir(to_file_name(id)))
    Metadata([entry[string(field)] for field in fieldnames(Metadata)]...)
end

Base.getindex(m::Metadata, field::String) = m.data[field]
function Base.setindex!(m::Metadata, val, field::String)
    m.data[field] = val
    @async save_metadata(m)
    return val
end

Base.keys(m::Metadata) = keys(m.data)
function Base.delete!(m::Metadata, field)
    delete!(m.data,field)
    @async save_metadata(m)
    return m
end

function rename!(m::Metadata, path)
    rel_path = relpath(path, projectdir())
    assert_metadata_directory()
    lock_metadata_directory()
    if find_file_in_index(rel_path) != nothing 
        unlock_metadata_directory()
        error("There is already metadata stored for '$path'.")
    end
    add_index_entry(m.id, rel_path)
    unlock_metadata_directory()
    m.path = rel_path
end

function Base.delete!(m::Metadata)
    assert_metadata_directory()
    lock_metadata_directory()
    file = metadatadir(to_file_name(m.id))
    if !isfile(file)
        unlock_metadata_directory()
        error("There is no metadata storage for id $(m.path)")
    end
    rm(file)
    remove_index_entry(m.id, m.path)
    unlock_metadata_directory()
end

function save_metadata(m::Metadata)
    BSON.bson(metadatadir(to_file_name(m.id)),Dict(string(field)=>getfield(m,field) for field in fieldnames(Metadata)))
    unlock_identifier(m.id)
end

get_first_identifier() = 1
from_file_name(x) = parse(Int,splitext(x)[1])
to_file_name(x) = string(x)*".bson"
to_lck_file_name(x) = string(x)*".lck"

function assert_metadata_directory()
    metadata_directory = metadatadir()
    if !isdir(metadata_directory)
        @info "Metadata directory not found, creating a new one"
        mkdir(metadata_directory)
        BSON.bson(metadataindex(),Dict{Int,String}())
    end
end

function get_next_identifier()
    files = filter(x->!(x in (metadata_lock, metadata_index)),readdir(metadatadir()))
    if length(files) == 0 
        next_id = get_first_identifier()
    else
        next_id = last(sort(from_file_name.(files)))+1
    end
    lock_identifier(next_id)
    return next_id
end

function lock_metadata_directory()
    for _ in 1:metadata_max_unlock_retries
        if !isfile(metadatalock())
            touch(metadatalock())
            return
        end
        sleep(metadata_sleep)
    end
    error("Could not retriev lock for metadata folder. Another process has locked the folder.")
end

function unlock_metadata_directory()
    if isfile(metadatalock())
        rm(metadatalock())
    else
        error("The metadata folder is currently unlocked")
   end
end

function lock_identifier(id)
    isfile(metadatadir(to_file_name(id))) && error("$id cannot be reserverd, it is already in use")
    isfile(metadatadir(to_lck_file_name(id))) && error("$id cannot be reserverd, it is already in locked by another process")
    touch(metadatadir(to_lck_file_name(id)))
end

function unlock_identifier(id)
    if isfile(metadatadir(to_lck_file_name(id)))
        rm(metadatadir(to_lck_file_name(id)))
    end
end

function Base.show(io::IO, m::Metadata)
    print(io, "Metadata with $(length(m.data)) entries:")
    for p in m.data
        println(io)
        print(io, "  \"$(p[1])\" =>")
    end
end

DrWatson.tag!(m::Metadata, args...; kwargs...) = tag!(m.data, args...; kwargs...)
