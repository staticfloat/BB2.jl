using NetworkOptions
export HostToolsToolchain

"""
    HostToolsToolchain

This toolchain contains a large number of useful host tools, such as 
"""
@kwdef struct HostToolsToolchain <: AbstractToolchain
    platform::Platform = HostPlatform()
    deps::Vector{AbstractSource}

    function HostToolsToolchain(platform, overrides=AbstractSource[])
        peel_host(p::Platform) = p
        peel_host(p::CrossPlatform) = p.host
        platform = peel_host(platform)

        # If the user is lazy and only gives us names, just turn them into JLLSource objects
        overrides = map(overrides) do tool
            if isa(tool, String)
                return JLLSource(tool, platform)
            end
            return tool
        end

        @warn("TODO: Version these by sticking them in a `Manifest.toml` somewhere for easy updating?")
        default_tools = [
            # Build tools
            "automake_jll",
            "autoconf_jll",
            "Bison_jll",
            "Ccache_jll",
            "file_jll",
            "flex_jll",
            "gawk_jll",
            "GNUMake_jll",
            "Libtool_jll",
            "M4_jll",
            "Patchelf_jll",
            "Perl_jll",
            "patch_jll",

            # Networking tools
            "CURL_jll",
            "Git_jll",

            # Compression tools
            "Tar_jll",
            "Gzip_jll",
            "Bzip2_jll",
            "Zstd_jll",
            "XZ_jll",
        ]

        deps = AbstractSource[]

        # Add any JLLS from our default tools that are not already in the overrides list, to prevent duplicates.
        override_jlls = filter(e -> isa(e, JLLSource), overrides)
        for tool in default_tools
            if !any(jll.package.name == tool for jll in override_jlls)
                push!(deps, JLLSource(tool, platform))
            end
        end
        for override in overrides
            push!(deps, override)
        end

        # Concretize the JLLSource's `PackageSpec`'s version now:
        jll_deps = JLLSource[d for d in deps if isa(d, JLLSource)]
        resolve_versions!(jll_deps; julia_version=nothing)

        return new(
            platform,
            deps,
        )
    end
end

function Base.show(io::IO, toolchain::HostToolsToolchain)
    println(io, "HostToolsToolchain ($(triplet(toolchain.platform)))")
    for dep in toolchain.deps
        println(io, " - $(dep.package.name[1:end-4]) v$(dep.package.version)")
    end
end

function toolchain_sources(toolchain::HostToolsToolchain)
    sources = AbstractSource[]

    push!(sources, GeneratedSource(;target="etc/certs") do out_dir
        cp(ca_roots_path(), joinpath(out_dir, basename(ca_roots_path())))
    end)

    push!(sources, GeneratedSource(;target="wrappers") do out_dir
        toolchain_prefix = "\$(dirname \"\${WRAPPER_DIR}\")"
        if any(jll.package.name == "Tar_jll" for jll in toolchain.deps)
            # Forcibly insert --no-same-owner into every tar invocation,
            # since we run in a single-user environment.
            compiler_wrapper(joinpath(out_dir, "tar"), "$(toolchain_prefix)/bin/tar") do io
                append_flags(io, :POST, "--no-same-owner")
            end
        end
        if any(jll.package.name == "Libtool_jll" for jll in toolchain.deps)
            # Libtool is annoying enough that I want it to show up when using `BB_WRAPPERS_VERBOSE=1`.
            compiler_wrapper(identity, joinpath(out_dir, "libtool"), "$(toolchain_prefix)/bin/libtool")
        end
        if any(jll.package.name == "file_jll" for jll in toolchain.deps)
            compiler_wrapper(joinpath(out_dir, "file"), "$(toolchain_prefix)/bin/file") do io
                # Fix relocatability issues
                println(io, """
                export MAGIC=$(toolchain_prefix)/share/misc/magic.mgc
                """)
            end
        end
        if any(jll.package.name == "Git_jll" for jll in toolchain.deps)
            compiler_wrapper(joinpath(out_dir, "git"), "$(toolchain_prefix)/bin/git") do io
                # Fix relocatability issues
                println(io, """
                export GIT_EXEC_PATH=\"$(toolchain_prefix)/libexec/git-core\"
                export GIT_SSL_CAINFO=\"$(toolchain_prefix)/etc/certs/$(basename(ca_roots_path()))\"
                export GIT_TEMPLATE_DIR=\"$(toolchain_prefix)/share/git-core/templates\"
                """)
            end
        end
        if any(jll.package.name == "automake_jll" for jll in toolchain.deps)
            # tell `aclocal` and `automake` how to find its own files
            for name in ("aclocal", "aclocal-1.16")
                compiler_wrapper(joinpath(out_dir, name), "$(toolchain_prefix)/bin/$(name)") do io
                    append_flags(io, :PRE, "--automake-acdir=$(toolchain_prefix)/share/aclocal-1.16")
                    append_flags(io, :PRE, "--system-acdir=$(toolchain_prefix)/share/aclocal")
                end
            end
            for name in ("automake", "automake-1.16")
                compiler_wrapper(joinpath(out_dir, name), "$(toolchain_prefix)/bin/$(name)") do io
                    append_flags(io, :PRE, "--libdir=$(toolchain_prefix)/share/automake-1.16")
                end
            end
        end
        if any(jll.package.name == "autoconf_jll" for jll in toolchain.deps)
            compiler_wrapper(joinpath(out_dir, "autom4te"), "$(toolchain_prefix)/bin/autom4te") do io
                println(io, """
                # Fix relocatability issues
                export AC_MACRODIR=$(toolchain_prefix)/share/autoconf
                export autom4te_perllibdir=$(toolchain_prefix)/share/autoconf
                """)
            end

            for name in ("autoconf", "autoreconf")
                compiler_wrapper(joinpath(out_dir, name), "$(toolchain_prefix)/bin/$(name)") do io
                    println(io, """
                    # Fix relocatability issues
                    export autom4te_perllibdir=$(toolchain_prefix)/share/autoconf
                    """)
                end
            end
        end
    end)

    append!(sources, toolchain.deps)
    return sources
end

function toolchain_env(::HostToolsToolchain, deployed_prefix::String; base_env = ENV)
    env = copy(base_env)
    
    insert_PATH!(env, :PRE, [
        joinpath(deployed_prefix, "wrappers"),
        joinpath(deployed_prefix, "bin"),
    ])
    env["PATCHELF"] = joinpath(deployed_prefix, "bin", "patchelf")
    insert_PATH!(env, :PRE, [
        joinpath(deployed_prefix, "share", "aclocal-1.16"),
        joinpath(deployed_prefix, "share", "automake-1.16"),
        joinpath(deployed_prefix, "share", "autoconf"),
    ]; varname="PERLLIB")
    # Tell automake not to try and use its baked-in paths
    env["AUTOMAKE_UNINSTALLED"] = "true"
    env["AUTOCONF"] = joinpath(deployed_prefix, "wrappers", "autoconf")
    env["AUTOM4TE"] = joinpath(deployed_prefix, "wrappers", "autom4te")
    env["M4"] = joinpath(deployed_prefix, "bin", "m4")
    return env
end

function platform(toolchain::HostToolsToolchain)
    return toolchain.platform
end
