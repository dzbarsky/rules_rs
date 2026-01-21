load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_rust//rust:rust_common.bzl", "CrateInfo", "CrateGroupInfo", "BuildInfo", "DepInfo", "DepVariantInfo")

def is_proc_macro(crate_info):
    return crate_info.type == "proc-macro"

def _rust_deps_impl(ctx):
    dep_variant_infos = []
    runfiles = []
    deps = []

    for dep in ctx.attr.deps:
        if CrateInfo in dep:
            crate_info = dep[CrateInfo]
            if is_proc_macro(crate_info) != ctx.attr.proc_macros:
                continue
            dep_variant_infos.append(DepVariantInfo(
                crate_info = crate_info,
                dep_info = dep[DepInfo] if DepInfo in dep else None,
                build_info = dep[BuildInfo] if BuildInfo in dep else None,
                cc_info = dep[CcInfo] if CcInfo in dep else None,
                crate_group_info = None,
            ))
            deps.append(dep)
        elif BuildInfo in dep:
            # Build scripts are always normal deps.
            if ctx.attr.proc_macros:
                continue
            dep_variant_infos.append(DepVariantInfo(
                crate_info = dep[CrateInfo] if CrateInfo in dep else None,
                dep_info = dep[DepInfo] if DepInfo in dep else None,
                build_info = dep[BuildInfo] if BuildInfo in dep else None,
                cc_info = dep[CcInfo] if CcInfo in dep else None,
                crate_group_info = None,
            ))
            deps.append(dep)
        elif CcInfo in dep:
            if ctx.attr.proc_macros:
                continue
            dep_variant_infos.append(DepVariantInfo(
                crate_info = None,
                dep_info = None,
                build_info = None,
                cc_info = dep[CcInfo],
                crate_group_info = None,
            ))

        if dep[DefaultInfo].default_runfiles != None:
            runfiles.append(dep[DefaultInfo].default_runfiles)

    providers = [
        CrateGroupInfo(
            dep_variant_infos = depset(dep_variant_infos),
        ),
        DefaultInfo(runfiles = ctx.runfiles().merge_all(runfiles)),
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["deps"],
        ),
    ]
    if len(deps) == 1 and ctx.attr.proc_macros:
        providers.append(deps[0][CrateInfo])
    return providers

rust_deps = rule(
    implementation = _rust_deps_impl,
    provides = [CrateGroupInfo],
    attrs = {
        "deps": attr.label_list(
            doc = "Other dependencies to forward through this crate group.",
            providers = [[BuildInfo], [CrateInfo], [CcInfo]],
        ),
        "proc_macros": attr.bool(),
    },
)
