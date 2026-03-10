def _verify_alias_impl(ctx):
    actual = ctx.attr.aliases.get(ctx.attr.expected_label)
    if actual != ctx.attr.expected_alias:
        fail(
            "Expected alias %r for %s, got %r from %r" % (
                ctx.attr.expected_alias,
                ctx.attr.expected_label,
                actual,
                ctx.attr.aliases,
            ),
        )

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

verify_alias = rule(
    implementation = _verify_alias_impl,
    attrs = {
        "aliases": attr.string_dict(mandatory = True),
        "expected_alias": attr.string(mandatory = True),
        "expected_label": attr.string(mandatory = True),
    },
)
