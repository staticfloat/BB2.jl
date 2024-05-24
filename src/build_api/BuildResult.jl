export BuildResult

"""
    BuildResult

A `BuildResult` represents a constructed build prefix; it contains the paths to the
binaries (typically within an artifact directory) as well as some metadata about the
audit passes and whatnot that ran upon the files.
"""
mutable struct BuildResult
    # The config that this result was built from
    config::BuildConfig

    # The overall status of the build.  One of [:success, :failed, :errored, :cached, :skipped]
    status::Symbol

    # If `status` is `:errored`, this should contain the exception that was thrown during execution
    # This generally denotes a bug.
    exception::Union{Nothing,Exception}

    # The executor and mounts used to run the build (also used to run the extraction)
    exe::Union{Nothing,SandboxExecutor}
    mounts::Dict{String,MountInfo}

    # Log from the build
    build_log::Union{Nothing,String}

    # The final environment of this build result.
    env::Dict{String,String}

    function BuildResult(config::BuildConfig,
                         status::Symbol,
                         exception::Union{Nothing,Exception},
                         exe::Union{Nothing,SandboxExecutor},
                         mounts::Dict{String,MountInfo},
                         build_log::AbstractString,
                         env::Dict{String,String} = parse_metadir_env(exe, config, mounts))
        obj = new(
            config,
            status,
            exception,
            exe,
            mounts,
            String(build_log),
            env,
        )
        # TODO: Provide a way to clean this up eagerly
        if obj.exe !== nothing
            atexit() do
                Sandbox.cleanup(obj.exe)
            end
        end
        return obj
    end
end

function BuildResult_cached(config::BuildConfig)
    build_hash = content_hash(config)
    log = config.meta.build_cache.logs[build_hash]
    env = config.meta.build_cache.envs[build_hash]
    return BuildResult(
        config,
        :cached,
        nothing,
        nothing,
        Dict{String,MountInfo}(),
        log,
        env,
    )
end

Sandbox.SandboxConfig(result::BuildResult; verbose::Bool = false) = SandboxConfig(result.config, result.mounts; verbose)

function runshell(result::BuildResult; verbose::Bool = false, shell::Cmd = `/bin/bash`)
    run(result.exe, SandboxConfig(result; verbose), shell)
end

function find_mount_for_path(mounts::Dict{String,MountInfo}, path::String)
    prefix_mounts = filter(collect(keys(mounts))) do m
        return startswith(path, m)
    end
    return first(sort(prefix_mounts; by=length))
end


function Base.read(exe::SandboxExecutor, config::BuildConfig, mounts::Dict{String,MountInfo}, filepath::String)
    stdout = IOBuffer()
    stderr = IOBuffer()
    sandbox_config = SandboxConfig(
        config, mounts;
        stdout=stdout,
        stderr=stderr,
    )

    # Find `cat` within the rootfs.
    cat_path = nothing
    for bindir in ("bin", "usr/bin", "usr/local/bin")
        shard_path = find_mount_for_path(mounts, string("/", bindir))
        if isfile(joinpath(shard_path, bindir, "cat"))
            cat_path = string("/", bindir, "/cat")
            break
        end
    end
    if cat_path === nothing
        throw(ArgumentError("Unable to find a `cat` executable within the rootfs?!"))
    end

    status, exception = run_trycatch(exe, sandbox_config, `$(cat_path) $(filepath)`)
    if exception !== nothing
        throw(exception)
    end
    if status !== :success
        throw(ArgumentError("Could not read file $(filepath): $(String(take!(stderr)))"))
    end
    return take!(stdout)
end

function parse_metadir_env(exe::SandboxExecutor, config::BuildConfig, mounts::Dict{String,MountInfo})
    return parse_env_block(String(read(exe, config, mounts, "/workspace/metadir/env")))
end

function parse_env_block(env_string::AbstractString)
    env = Dict{String,String}()
    for line in split(env_string, "\n")
        sep_idx = findfirst("=", line)
        if sep_idx !== nothing
            env[line[1:first(sep_idx)-1]] = line[first(sep_idx)+1:end]
        end
    end
    return env
end

# The opposite of `parse_env_block`
function serialize_env_block(env::Dict{String,String})
    return join((string(key, "=", env[key]) for key in sort(collect(keys(env)))), "\n")
end

# TODO: construct helper to reconstruct BuildResult objects from S3-saved tarballs
