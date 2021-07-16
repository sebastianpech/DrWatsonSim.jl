export get_metadata

function get_metadata(search_path::String; include_parents=true)
    while search_path != ""
        id = find_file_in_index(search_path)
        if id != nothing
            return Metadata(search_path)
        end
        include_parents || return nothing
        search_path, _ = splitdir(search_path)
    end
    return nothing
end

function get_metadata(f::Function)
    ms = Metadata[]
    for file in filter(x->endswith(x,".bson"),readdir(metadatadir()))
        m = load_metadata(joinpath(metadatadir(),file), ignore_exceptions=true)
        m === nothing && continue
        f(m) && push!(ms, m)
    end
    return ms
end

function get_metadata() 
    return get_metadata() do m
        true
    end
end

function get_metadata(field::String, value) 
    return get_metadata() do m
        field in keys(m) && m[field] == value
    end
end
