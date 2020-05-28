export get_metadata

function safe_load_index()
    lock("metadata")
    semaphore_enter("indexread")
    unlock("metadata")
    index = BSON.load(metadataindex())
    semaphore_exit("indexread")
    return index
end

function get_metadata(path::String; include_parents=true)
    rel_path = relpath(path, projectdir())
    index = safe_load_index()
    search_path = rel_path
    while search_path != ""
        id = find_file_in_index(search_path, index=index)
        if id != nothing
            return Metadata(id)
        end
        include_parents || return nothing
        search_path, _ = splitdir(search_path)
    end
    return nothing
end

function get_metadata(f::Function)
    index = safe_load_index()
    ms = Metadata[]
    for id in keys(index)
        m = Metadata(id)
        f(m) && push!(ms, m)
    end
    return ms
end

function get_metadata(field::String, value) 
    return get_metadata() do m
        field in keys(m) && m[field] == value
    end
end
