load(":rust_deps.bzl", "rust_deps")

def all_crate_deps(
        dep_data,
        normal = False,
        #normal_dev = False,
        proc_macro = False,
        #proc_macro_dev = False,
        build = False,
        build_proc_macro = False,
        filter_prefix = None):
    to_return = []

    deps = dep_data["deps"]
    build_deps = dep_data["build_deps"]

    if filter_prefix:
        deps = [dep for dep in deps if dep.startswith(filter_prefix)]
        build_deps = [dep for dep in build_deps if dep.startswith(filter_prefix)]

    if build_proc_macro:
        rust_deps(
            name = "_build_script_proc_macro_deps",
            deps = build_deps,
            proc_macros = True,
        )
        to_return.append("_build_script_proc_macro_deps")

    if build:
        rust_deps(
            name = "_build_script_deps",
            deps = build_deps,
        )
        to_return.append("_build_script_deps")

    if proc_macro:
        rust_deps(
            name = "_proc_macro_deps",
            deps = deps,
            proc_macros = True,
        )
        to_return.append("_proc_macro_deps")

    if normal or not to_return:
        rust_deps(
            name = "_deps",
            deps = deps,
        )
        to_return.append("_deps")

    return to_return
