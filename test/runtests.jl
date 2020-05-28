using Pkg
using DrWatsonSim
const ds = DrWatsonSim
using Test
using BSON
using DrWatson
using Dates

include("helper_functions.jl")

@testset "DrWatsonSim.jl" begin
    @testset "Metadata" begin
        @eval ds max_lock_retries = 10
        dummy_project() do folder
            @testset "Locking functions" begin 
                @test_logs (:info, r"creating") ds.assert_metadata_directory()
                # Check if index file was created
                @test isfile(joinpath(folder,ds.metadata_folder_name,ds.metadata_index))
                index = BSON.load(ds.metadataindex())
                @test index == Dict{Int,Any}()
                ds.lock("metadata")
                @test isdir(ds.metadatadir("metadata.lck"))
                ds.lock("foo")
                @test isdir(ds.metadatadir("foo.lck"))
                @test_throws ErrorException ds.lock("foo")
                ds.unlock("foo")
                ds.lock("foo")
                ds.unlock("foo")
                @test_throws ErrorException ds.lock("metadata")
                @test_throws ErrorException ds.lock("metadata")
                ds.unlock("metadata")
                @test_throws ErrorException ds.unlock("metadata")
                ds.lock("metadata")
                ds.unlock("metadata")
                ds.reserve_identifier(1)            
                @test isfile(ds.metadatadir(ds.to_reserved_identifier_name(1)))
                @test_throws ErrorException ds.reserve_identifier(1)
                ds.free_identifier(1)
                @test !isfile(ds.metadatadir(ds.to_reserved_identifier_name(1)))
                @test ds.semaphore_status("bar") == 0
                ds.semaphore_enter("bar")
                @test isfile(ds.metadatadir("bar.sem"))
                ds.semaphore_enter("bar")
                ds.semaphore_enter("bar")
                @test ds.semaphore_status("bar") == 3
                ds.semaphore_exit("bar")
                @test ds.semaphore_status("bar") == 2
                ds.semaphore_exit("bar")
                @test ds.semaphore_status("bar") == 1
                ds.semaphore_exit("bar")
                @test ds.semaphore_status("bar") == 0
                @test !isfile(ds.metadatadir("bar.sem"))
                @test_throws ErrorException ds.semaphore_exit("bar")
                function sem_test()
                    function blocked_worker(v)
                        ds.lock("foo", wait_for_semaphore="bar")
                        v[1]=1
                        ds.unlock("foo")
                    end
                    v = [0]
                    ds.semaphore_enter("bar")
                    @async blocked_worker(v)
                    @test v[1] == 0
                    ds.semaphore_enter("bar")
                    @test v[1] == 0
                    ds.semaphore_exit("bar")
                    ds.semaphore_exit("bar")
                    yield()
                    @test v[1] == 1
                end
                @sync sem_test()
            end
        end


        dummy_project() do folder
            @testset "Identifer Creation" begin
                ds.assert_metadata_directory()
                id = ds.get_next_identifier()
                @test id == 1
                @test isfile(ds.metadatadir(ds.to_reserved_identifier_name(1)))
                ds.free_identifier(1)
                id = ds.get_next_identifier()
                @test id == 1
                id = ds.get_next_identifier()
                @test id == 2
            end
        end

        dummy_project() do folder
            @testset "Metadata creation" begin
                m = Metadata(datadir("fileA"))
                mb = Metadata(datadir("fileB"))
                @test m.path == joinpath("data","fileA")
                @test isfile(ds.metadatadir(ds.to_file_name(1)))
                @test isfile(ds.metadatadir(ds.to_file_name(2)))
                @test m.mtime == 0
                index = BSON.load(ds.metadataindex())
                @test index[1] == joinpath("data","fileA")
                @test index[2] == joinpath("data","fileB")
                m2 = Metadata(datadir("fileA"))
                @test m.id == m2.id
                m3 = Metadata(1)
                @test m.path == m3.path
                touch(datadir("fileA"))
                @test_logs (:warn, r"changed") Metadata(datadir("fileA"))
                @test_nowarn m = Metadata!(datadir("fileA"))
                @test m.mtime > 0
                A = rand(3,3)
                m["some_data"] = A
                yield() # Allow async task to finish
                raw_loaded = BSON.load(ds.metadatadir(ds.to_file_name(1)))
                @test raw_loaded["data"]["some_data"] == A
                id = ds.reserve_next_identifier()
                @test id == 3
                @test isfile(ds.metadatadir(ds.to_reserved_identifier_name(3)))
                @test !isfile(ds.metadatadir(ds.to_file_name(3)))
                m = Metadata(datadir("fileC"))
                @test m.id == 4
                m = Metadata(id, datadir("fileD"))
                @test !isfile(ds.metadatadir(ds.to_reserved_identifier_name(3)))
                @test isfile(ds.metadatadir(ds.to_file_name(3)))
                id = ds.reserve_next_identifier()
                @test_throws ErrorException Metadata(id, datadir("fileD"))
                m = Metadata(datadir("fileD"))
                rename!(m, datadir("fileE"))
                index = BSON.load(ds.metadataindex())
                @test index[m.id] == joinpath("data","fileE")
                Metadata(id, datadir("fileD"))
                index = BSON.load(ds.metadataindex())
                @test index[id] == joinpath("data","fileD")
            end
        end

        dummy_project() do folder
            @testset "Metadata Pentest" begin
                ds.assert_metadata_directory()
                @sync for i in 1:500
                    @async begin
                        m = Metadata(datadir("file$i"))
                        s = rand(1:100)
                        m["data"] = rand(s,s)
                        for j in 1:10
                            rename!(m, datadir("file$(m.id)_$(j)"))
                        end
                    end
                end
                index = BSON.load(ds.metadataindex())
                for id in keys(index)
                    m = Metadata(id)
                    @test index[id] == joinpath("data","file$(id)_10")
                end
            end
        end
    end
    @testset "Simulations" begin
        @eval ds max_lock_retries = 10000
        dummy_project() do folder
            @testset "long running computation" begin
                Pkg.develop(PackageSpec(url=joinpath(@__DIR__,"..")))
                pkg"add BSON"
                pkg"add Dates"
                file = scriptsdir("long_running_script.jl")
                cp(joinpath(@__DIR__, "long_running_script.jl"), file)
                run(`julia $file`)
                for i in 1:9
                    folder = datadir("sims","$i")
                    file = datadir("sims","$i","output.bson")
                    @test isfile(file)
                    result = BSON.load(file)[:result]
                    m = Metadata(folder)
                    p = m["parameters"]
                    @test p[:a]^p[:b] == result
                    @test m.path == Metadata(i).path
                    @test m["type"] == "Simple Computation"
                    @test m["started at"] < now()
                    m_new = Metadata(joinpath(folder,"newfile"))
                    @test m_new["extra"] == "This should be blocked"
                end
            end
        end
    end
end
