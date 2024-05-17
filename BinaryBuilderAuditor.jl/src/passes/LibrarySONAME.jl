using ObjectFile, Patchelf_jll


"""
    ensure_sonames!(scan::ScanResult)

We want all libraries to have consistent SONAMEs.  This makes it much easier to
ensure that dependencies are matched up properly when loading, since we rely
upon the dynamic linker's SONAME short-circuit when loading transitive library
dependencies. To enforce this, we ensure that every non-Windows target has a
reasonable SONAME in all of its libraries.
"""
function ensure_sonames!(scan::ScanResult; verbose::Bool = false)
    # Windows doesn't do SONAMEs
    if Sys.iswindows(scan.platform)
        return
    end

    for (rel_path, oh) in scan.binary_objects
        if !islibrary(oh)
            continue
        end

        soname = get_soname(oh)
        if soname === nothing
            abs_path = abspath(scan, rel_path)
            soname = basename(rel_path)

            if verbose
                @info("Adding SONAME to library", rel_path, soname)
            end

            if Sys.isapple(scan.platform)
                cmd = `-id $(soname) $(abs_path)`
            elseif Sys.islinux(scan.platform) || Sys.isbsd(scan.platform)
                cmd = `$(patchelf()) $(patchelf_flags(scan.platform)) --set-soname $(soname) $(abs_path)`
            end

            proc, output = capture_output(cmd)
            if !success(proc)
                println(String(take!(output)))
                @error("Unable to set SONAME on library", rel_path)
                error()
            end

            # Refresh our ObjectHandle, since the above manipulation
            # may have completely re-arranged things.
            refresh!(scan, rel_path)
        end
    end
end

function get_soname(oh::ELFHandle)
    # Get the dynamic entries, see if it contains a DT_SONAME
    es = ELFDynEntries(oh)
    soname_idx = findfirst(e -> e.entry.d_tag == ELF.DT_SONAME, es)
    if soname_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Look up the SONAME from the string table
    return strtab_lookup(es[soname_idx])
end

function get_soname(oh::MachOHandle)
    # Get the dynamic entries, see if it contains an ID_DYLIB_CMD
    lcs = MachOLoadCmds(oh)
    id_idx = findfirst(lc -> typeof(lc) <: MachOIdDylibCmd, lcs)
    if id_idx === nothing
        # If all else fails, just return the filename.
        return nothing
    end

    # Return the Dylib ID
    return dylib_name(lcs[id_idx])
end

function get_soname(scan::ScanResult, lib::LibraryProduct)
    lib_path = relpath(scan, scan.library_products[lib])
    return get_soname(scan.binary_objects[lib_path])
end
