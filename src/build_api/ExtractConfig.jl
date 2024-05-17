using Sandbox, TreeArchival, Pkg, BinaryBuilderProducts, Artifacts, BinaryBuilderAuditor

export ExtractConfig, extract!

struct ExtractConfig
    # The build result we're packaging up
    build::BuildResult

    # The extraction script that we're using to copy build results out into our artifacts
    script::String

    # The products that this package will ensure are available
    products::Vector{<:AbstractProduct}

    # TODO: Add an `AuditConfig` field
    #audit::AuditConfig
    metadir::String

    # Timing
    to::TimerOutput

    function ExtractConfig(build::BuildResult,
                           script::AbstractString,
                           products::Vector{<:AbstractProduct};
                           metadir = mktempdir(builds_dir()),
                           audit_config = nothing)
        # We want to copy the metadir from the BuildConfig and add our own
        # extraction script.  We copy here so that bash history and whatnot is preserved,
        # but unique for this extraction config.
        rm(metadir)
        cp(build.mounts["/workspace/metadir"].host_path, metadir)

        extract_script_path = joinpath(metadir, "extract_script.sh")
        open(extract_script_path, write=true) do io
            println(io, "#!/bin/bash")
            println(io, "set -euo pipefail")
            println(io, "source /usr/local/share/bb/save_env_hook")
            println(io, "source /usr/local/share/bb/extraction_utils")
            println(io, script)
            println(io, "auto_install_license")
            println(io, "exit 0")
        end
        chmod(extract_script_path, 0o755)

        return new(
            build,
            String(script),
            products,
            metadir,
            copy(build.config.to),
        )
    end
end

function runshell(config::ExtractConfig; output_dir::String=mktempdir(builds_dir()), shell::Cmd = `/bin/bash`)
    sandbox_config = SandboxConfig(config, output_dir)
    run(config.build.exe, sandbox_config, shell)
end

function SandboxConfig(config::ExtractConfig, output_dir::String; kwargs...)
    # We're going to alter the mounts of the build a bit for extraction.
    mounts = copy(config.build.mounts)

    # First, we're going swap out any mounts for deployed sources in `${prefix}`
    # This results in `${prefix}` containing only the files that were added by our build
    for dest in keys(mounts)
        if startswith(dest, "/workspace/destdir/")
            mounts[dest] = MountInfo(mktempdir(), MountType.Overlayed)
        end
    end

    # Insert our new metadir
    mounts["/workspace/metadir"] = MountInfo(config.metadir, MountType.Overlayed)

    # Insert our extraction dir, which is a ReadWrite mount,
    # allowing us to pull the result back out from the overlay nest.
    mounts["/workspace/extract"] = MountInfo(output_dir, MountType.ReadWrite)

    # Insert some more environment variables on top of what was defined by the build config
    env = copy(config.build.config.env)
    env["extract_dir"] = "/workspace/extract"
    env["BB_WRAPPERS_VERBOSE"] = "true"
    return SandboxConfig(config.build.config, mounts; env, kwargs...)
end

function extract!(config::ExtractConfig)
    local artifact_hash, run_status, run_exception, audit_result
    build_config = config.build.config
    meta = build_config.meta
    @timeit config.to "extract" begin
        in_universe(meta.universe) do env
            artifact_hash = Pkg.Artifacts.create_artifact() do artifact_dir
                sandbox_config = SandboxConfig(config, artifact_dir)
                run_status, run_exception = run_trycatch(config.build.exe, sandbox_config, `/workspace/metadir/extract_script.sh`)

                # Before the artifact is sealed, we run our audit passes, as they may alter the binaries
                @timeit config.to "audit" begin
                    prefix_alias = "/workspace/destdir/$(triplet(build_config.platform.target))"
                    # Load JLLInfo structures for each dependency
                    dep_jll_infos = JLLInfo[parse_toml_dict(d; depot=meta.universe.depot_path) for d in build_config.source_trees[prefix_alias] if isa(d, JLLSource)]
                    audit_result = audit!(
                        artifact_dir,
                        LibraryProduct[p for p in config.products if isa(p, LibraryProduct)],
                        dep_jll_infos;
                        prefix_alias,
                        env = build_config.env,
                        verbose = meta.verbose,
                    )
                end
            end
        end
    end

    # Run over the extraction result, ensure that all products can be located:
    unlocatable_products = AbstractProduct[]
    extract_prefix = artifact_path(meta.universe, artifact_hash)
    for product in config.products
        if locate(product, extract_prefix;
                  env=config.build.env) === nothing
            push!(unlocatable_products, product)
        end
    end

    if !isempty(unlocatable_products)
        @error("Unable to locate $(length(unlocatable_products)) products:", unlocatable_products, platform=config.build.config.platform)
        error()
    end

    result = ExtractResult(
        config,
        run_status,
        run_exception,
        artifact_hash,
        audit_result,
        Dict{String,String}(),
    )
    meta.extractions[config] = result
    return result
end
