def run_toml2json(ctx, wasm_blob, toml_file):
    if wasm_blob == None:
        result = ctx.execute([Label("@toml2json_host_bin//:toml2json"), toml_file])
        if result.return_code != 0:
            fail(result.stdout + result.stderr)

        return json.decode(result.stdout)
    else:
        data = ctx.read(toml_file)
        result = ctx.execute_wasm(wasm_blob, "toml2json", input = data)
        if result.return_code != 0:
            fail(result.output)

        return json.decode(result.output)