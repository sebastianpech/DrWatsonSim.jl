export Metadata, Metadata!, rename!, delete!

const metadata_folder_name = ".metadata"
const metadata_index = "index.bson"
const metadata_lock = "metadata.lck"
const max_lock_retries = 10000

metadatadir(args...) = projectdir(metadata_folder_name, args...)
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
    rel_path = relpath(path, projectdir())
    # Check if there is already an entry for that file in the index
    lock("metadata")
    semaphore_enter("indexread")
    unlock("metadata")
    _id = find_file_in_index(rel_path)
    semaphore_exit("indexread")
    if _id != nothing && !overwrite
        m = Metadata(_id)
        if m.mtime != mtime(path) && isfile(path)
            @warn "The metadata entries might not be up to date. The file changed after adding the entries"
        end
    elseif _id != nothing && overwrite
        m = Metadata(_id, rel_path, mtime(path), Dict{String,Any}())
        save_metadata(m)
    else
        lock("metadata", wait_for_semaphore="indexread")
        m = Metadata(get_next_identifier(), rel_path, mtime(path), Dict{String,Any}())
        add_index_entry(m.id, m.path)
        save_metadata(m)
        unlock("metadata")
    end
    return m
end

function Metadata(id::Int, path::String)
    assert_metadata_directory()
    lck_path = metadatadir(to_reserved_identifier_name(id))
    rel_path = relpath(path, projectdir())
    lock("metadata", wait_for_semaphore="indexread")
    if !isfile(lck_path) 
        unlock("metadata")
        error("No locked metadata file with id '$id'")
    end
    if find_file_in_index(rel_path) != nothing 
        unlock("metadata")
        error("There is already metadata stored for '$path'.")
    end
    m = Metadata(id, rel_path, mtime(rel_path), Dict{String, Any}())
    add_index_entry(m.id, m.path)
    save_metadata(m)
    unlock("metadata")
    return m
end

function Metadata(id::Int)
    path = metadatadir(to_file_name(id))
    isfile(path) || error("No metadata entry for id '$id'")
    entry = BSON.load(metadatadir(to_file_name(id)))
    Metadata([entry[string(field)] for field in fieldnames(Metadata)]...)
end

function reserve_next_identifier()
    assert_metadata_directory()
    lock("metadata")
    id = get_next_identifier()
    unlock("metadata")
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

function find_file_in_index(path; index = BSON.load(metadataindex()))
    for id in keys(index)
        if index[id] == path 
            return id
        end
    end
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
    lock("metadata", wait_for_semaphore="indexread")
    if find_file_in_index(rel_path) != nothing 
        unlock("metadata")
        error("There is already metadata stored for '$path'.")
    end
    add_index_entry(m.id, rel_path)
    unlock("metadata")
    m.path = rel_path
end

function Base.delete!(m::Metadata)
    assert_metadata_directory()
    lock("metadata", wait_for_semaphore="indexread")
    file = metadatadir(to_file_name(m.id))
    if !isfile(file)
        unlock("metadata")
        error("There is no metadata storage for id $(m.path)")
    end
    rm(file)
    remove_index_entry(m.id, m.path)
    unlock("metadata")
end

function save_metadata(m::Metadata)
    BSON.bson(metadatadir(to_file_name(m.id)),Dict(string(field)=>getfield(m,field) for field in fieldnames(Metadata)))
    free_identifier(m.id)
end

get_first_identifier() = 1
from_file_name(x) = parse(Int,splitext(x)[1])
to_file_name(x) = string(x)*".bson"
to_reserved_identifier_name(x) = string(x)*".reserved"

function assert_metadata_directory()
    metadata_directory = metadatadir()
    if !isdir(metadata_directory)
        @info "Metadata directory not found, creating a new one"
        try
            mkdir(metadata_directory)
            BSON.bson(metadataindex(),Dict{Int,String}())
        catch e
            if e.code != -17
                rethrow(e)
            end
        end
    end
end

function get_next_identifier()
    files = filter(x-> x != metadata_index && !(splitext(x)[2] in (".sem", ".lck")),readdir(metadatadir()))
    if length(files) == 0 
        next_id = get_first_identifier()
    else
        next_id = last(sort(from_file_name.(files)))+1
    end
    reserve_identifier(next_id)
    return next_id
end

function lock(name; wait_for_semaphore="")
    lock_path =  metadatadir("$name.lck")
    for _ in 1:max_lock_retries
        if wait_for_semaphore == "" || semaphore_status(wait_for_semaphore) == 0
            try
                mkdir(lock_path)
                return
            catch e
                sleep(0.1)
            end
        end
    end
    error("Could not retriev lock $name")
end  

function unlock(name)
    lock_path =  metadatadir("$name.lck")
    try
        mkdir(lock_path)
    catch e
        rm(lock_path)
        return
    end
    rm(lock_path)
    error("$name is currently unlocked.")
end

function semaphore_status(name)
    sem_path =  metadatadir("$name.sem")
    lock(name)
    if isfile(sem_path)
        n = parse(Int,read(sem_path,String))
    else
        n = 0
    end
    unlock(name)
    return n
end

function semaphore_enter(name)
    sem_path =  metadatadir("$name.sem")
    lock(name)
    if isfile(sem_path)
        n = parse(Int,read(sem_path,String))
    else
        n = 0
    end
    open(sem_path,"w") do f
        write(f, string(n+1))
    end
    unlock(name)
end

function semaphore_exit(name)
    sem_path =  metadatadir("$name.sem")
    lock(name)
    if isfile(sem_path)
        n = parse(Int,read(sem_path,String))
        if n == 1
            rm(sem_path)
        else
            open(sem_path,"w") do f
                write(f, string(n-1))
            end
        end
    else
        unlock(name)
        error("Semaphore $name is out of balance. Expected a file but there is none")
    end
    unlock(name)
end

function reserve_identifier(id)
    isfile(metadatadir(to_file_name(id))) && error("$id cannot be reserverd, it is already in use")
    isfile(metadatadir(to_reserved_identifier_name(id))) && error("$id cannot be reserverd, it is already in locked by another process")
    touch(metadatadir(to_reserved_identifier_name(id)))
end

function free_identifier(id)
    if isfile(metadatadir(to_reserved_identifier_name(id)))
        rm(metadatadir(to_reserved_identifier_name(id)))
    end
end

function Base.show(io::IO, m::Metadata)
    print(io, "Metadata with $(length(m.data)) entries:")
    for p in m.data
        println(io)
        print(io, "  \"$(p[1])\" =>")
    end
end

function DrWatson.tag!(m::Metadata, args...; kwargs...) 
    tag!(m.data, args...; kwargs...)
    return m
end
