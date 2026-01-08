load(":rust_deps.bzl", _rust_deps = "rust_deps")

def rust_deps(name, **kwargs):
    if native.existing_rule(name):
        fail("""
ERROR: Multiple conflicting uses of `all_crate_deps`. If you are trying to use this macro with
the same args in multiple targets, please try the following pattern:

_DEPS = all_crate_deps()
_PROC_MACRO_DEPS = all_crate_deps(proc_macro = True)

rust_library(
    name = "my_lib",
    deps = _DEPS,
    proc_macro_deps = _PROC_MACRO_DEPS,
    ...
)

rust_test(
    name = "my_test",
    deps = [":my_lib"]+ _DEPS,
    proc_macro_deps = _PROC_MACRO_DEPS,
    ...
)""")

    _rust_deps(
        name = name,
        **kwargs
    )

def all_crate_deps(
        dep_data,
        normal = False,
        normal_dev = False,
        proc_macro = False,
        proc_macro_dev = False,
        build = False,
        build_proc_macro = False,
        filter_prefix = None):
    to_return = []

    deps = dep_data["deps"]
    build_deps = dep_data["build_deps"]
    dev_deps = dep_data["dev_deps"]

    if filter_prefix:
        deps = [dep for dep in deps if dep.startswith(filter_prefix)]
        build_deps = [dep for dep in build_deps if dep.startswith(filter_prefix)]

    if normal_dev:
        rust_deps(
            name = "_dev_deps",
            deps = dev_deps,
        )
        to_return.append("_dev_deps")

    if proc_macro:
        rust_deps(
            name = "_proc_macro_deps",
            deps = deps,
            proc_macros = True,
        )
        to_return.append("_proc_macro_deps")

    if proc_macro_dev:
        rust_deps(
            name = "_proc_macro_dev_deps",
            deps = dev_deps,
            proc_macros = True,
        )
        to_return.append("_proc_macro_dev_deps")

    if build:
        rust_deps(
            name = "_build_script_deps",
            deps = build_deps,
        )
        to_return.append("_build_script_deps")

    if build_proc_macro:
        rust_deps(
            name = "_build_script_proc_macro_deps",
            deps = build_deps,
            proc_macros = True,
        )
        to_return.append("_build_script_proc_macro_deps")

    if normal or not to_return:
        rust_deps(
            name = "_deps",
            deps = deps,
        )
        to_return.append("_deps")

    return to_return
