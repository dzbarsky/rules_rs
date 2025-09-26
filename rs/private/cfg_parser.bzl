def _get(xs, index, default):
    if index < len(xs):
        return xs[index]
    return default

def _emit_pending(frames, pending_ident, pending_eq_key):
    # Moves any pending identifier into a predicate node in the current frame.
    # If an '=' was seen but no string yet, that's a syntax error.
    if pending_eq_key:
        fail("cfg parse error: expected string literal after '=' for key '" + pending_eq_key[:-2] + "'.")
    if pending_ident:
        frames[len(frames)-1]["args"].append({"kind": "pred", "name": pending_ident})

############################################
# Tokenizer
############################################

# Tokens: IDENT(name), STRING(value), LPAREN, RPAREN, COMMA, EQ
def _cfg_tokenize(expr):
    tokens = []
    ident_buf = []
    str_buf = []
    in_string = False
    in_escape = False

    for ch in expr.elems():
        if in_string:
            if in_escape:
                str_buf.append(ch)
                in_escape = False
            elif ch == "\\":
                in_escape = True
            elif ch == "\"":
                tokens.append({"t": "STRING", "v": "".join(str_buf)})
                str_buf = []
                in_string = False
            else:
                str_buf.append(ch)
        else:
            if ch.isalpha() or ch == "_" or (ident_buf and ch.isdigit()):
                ident_buf.append(ch)
            else:
                if ident_buf != []:
                    tokens.append({"t": "IDENT", "v": "".join(ident_buf)})
                    ident_buf = []
                if ch == "(":
                    tokens.append({"t": "LPAREN"})
                elif ch == ")":
                    tokens.append({"t": "RPAREN"})
                elif ch == ",":
                    tokens.append({"t": "COMMA"})
                elif ch == "=":
                    tokens.append({"t": "EQ"})
                elif ch == "\"":
                    in_string = True
                # ignore whitespace/other

    if in_string:
        fail("cfg parse error: unterminated string literal.")
    if ident_buf:
        tokens.append({"t": "IDENT", "v": "".join(ident_buf)})
    return tokens


############################################
# Parser (non-recursive; stack of frames)
############################################

def cfg_parse(expr):
    tokens = _cfg_tokenize(expr)
    frames = [{"fn": "__ROOT__", "args": []}]
    pending_ident = None
    pending_eq_key = None

    for t in tokens:
        kind = t["t"]
        if kind == "IDENT":
            pending_ident = t["v"]
        elif kind == "LPAREN":
            if not pending_ident:
                fail("cfg parse error: '(' not following identifier.")
            frames.append({"fn": pending_ident, "args": []})
            pending_ident = None
        elif kind == "EQ":
            if not pending_ident:
                fail("cfg parse error: '=' must follow a key identifier.")
            pending_eq_key = pending_ident
            pending_ident = None
        elif kind == "STRING":
            if not pending_eq_key:
                fail("cfg parse error: string literal not expected here.")
            if pending_eq_key == "feature":
                fail("Feature evaluation in cfg is unsupported!")
            frames[-1]["args"].append({
                "kind": "eq",
                "key": pending_eq_key,
                "value": t["v"],
            })
            pending_eq_key = None
        elif kind == "COMMA":
            _emit_pending(frames, pending_ident, pending_eq_key)
            pending_ident = None
        elif kind == "RPAREN":
            _emit_pending(frames, pending_ident, pending_eq_key)
            pending_ident = None
            closed = frames.pop()
            if not frames:
                fail("cfg parse error: too many closing ')'.")
            fname = closed["fn"]
            args_list = closed["args"]
            parent = frames[-1]["args"]
            if fname == "cfg":
                if len(args_list) != 1:
                    fail("cfg parse error: cfg(...) must contain a single expression.")
                parent.append(args_list[0])
            elif fname == "all":
                parent.append({"kind": "all", "args": args_list})
            elif fname == "any":
                parent.append({"kind": "any", "args": args_list})
            elif fname == "not":
                if len(args_list) != 1:
                    fail("cfg parse error: not(...) must have exactly one argument.")
                parent.append({"kind": "not", "args": args_list})
            else:
                fail("cfg parse error: unknown function '" + fname + "'.")
        else:
            fail("cfg parse error: unknown token kind.")

    _emit_pending(frames, pending_ident, pending_eq_key)
    pending_ident = None

    if len(frames) != 1:
        fail("cfg parse error: unbalanced parentheses.")

    root_args = frames[0]["args"]
    if len(root_args) != 1:
        if not root_args:
            fail("cfg parse error: empty expression.")
        fail("cfg parse error: multiple top-level expressions; wrap with all(...)/any(...).")

    return root_args[0]

############################################
# Triple → cfg attribute derivation
############################################

def _normalize_os(os_raw):
    if os_raw == "darwin":
        return "macos"
    return os_raw

def _family_for_os(os_name):
    if os_name == "windows":
        return "windows"
    if os_name in [
        "linux", "macos", "ios", "freebsd", "netbsd", "openbsd", "dragonfly",
        "android", "solaris", "illumos", "aix", "haiku", "hurd",
    ]:
        return "unix"
    return ""

def _pointer_width_for_arch(arch):
    # Common targets
    arch64 = ["s390x","bpfel","bpfeb"]
    if "64" in arch or arch in arch64:
        return "64"

    arch32 = [
        "i686","i586","i386","x86","arm","armv7","thumbv7","thumbv6","mips","mipsel",
        "powerpc","ppc","sparc","riscv32","wasm32","m68k","loongarch32",
    ]
    if "32" in arch or arch in arch32:
        return "32"

    return "64"

def _endian_for_arch(arch):
    big_set = ["m68k","s390x","sparc","sparc64","powerpc","powerpc64"]
    if arch.endswith("be") or arch.endswith("eb") or arch in big_set:
        return "big"
    if arch.startswith("mips") and (not arch.endswith("el")):
        return "big"

    # Most contemporary targets are little-endian:
    return "little"

def _abi_from_env(env):
    # Very rough: surface a few commonly referenced ABIs
    abi_pieces = ["eabi", "eabihf", "elf", "gnuabi64"]
    for abi_piece in abi_pieces:
        if abi_piece in env:
            return abi_piece
    return ""

def triple_to_cfg_attrs(triple, features, target_features):
    parts = triple.split("-")
    arch_part = _get(parts, 0, "")
    vendor_part = _get(parts, 1, "unknown")
    os_raw_part = _get(parts, 2, "none")
    env_part = "-".join(parts[3:])
    os_norm = _normalize_os(os_raw_part)
    fam = _family_for_os(os_norm)
    width = _pointer_width_for_arch(arch_part)
    endian = _endian_for_arch(arch_part)
    abi_guess = _abi_from_env(env_part)

    return {
        "_triple": triple,

        "target_arch": arch_part,
        "target_vendor": vendor_part,
        "target_os": os_norm,
        "target_env": env_part,
        "target_family": fam,
        "target_endian": endian,
        "target_pointer_width": width,
        "target_abi": abi_guess,

        # convenience booleans for bare predicates
        "true": True,
        "false": False,
        "unix": fam == "unix",
        "windows": fam == "windows",

        # feature sets
        #"__features__": dict(((f, True) for f in features)),
        #"__tfeatures__": dict(((tf, True) for tf in target_features)),
    }

############################################
# Evaluator (non-recursive; explicit stack)
############################################

def _eval_eq(ctx, key, value):
    if key == "feature":
        return ctx.get("__features__", {}).get(value, False)
    if key == "target_feature":
        return ctx.get("__tfeatures__",
                       {}).get(value, False)
    known = [
        "target_os","target_family","target_arch","target_env",
        "target_vendor","target_endian","target_pointer_width","target_abi",
    ]
    if key in known:
        return ctx.get(key, "") == value
    # Unknown keys evaluate to False
    # fail("Unknown key %s" % key)
    return False

def _eval_pred(ctx, name):
    return ctx.get(name, False)


def _cfg_eval(ast, ctx):
    todo = [{"op": "VISIT", "node": ast}]
    results = []
    for _ in range(200000):
        if not todo:
            break
        instr = todo.pop()
        op = instr["op"]
        if op == "VISIT":
            node = instr["node"]
            kind = node["kind"]
            if kind == "pred":
                results.append(_eval_pred(ctx, node["name"]))
            elif kind == "eq":
                results.append(_eval_eq(ctx, node["key"], node["value"]))
            else:
                children = node["args"]
                n = len(children)
                todo.append({"op": "REDUCE", "name": kind, "n": n})
                for child in reversed(children):
                    todo.append({"op": "VISIT", "node": child})
        else:  # REDUCE
            name = instr["name"]
            n = instr["n"]
            if name == "all":
                ok = True
                for _ in range(n):
                    if not results.pop():
                        ok = False
                results.append(ok)
            elif name == "any":
                ok = False
                for _ in range(n):
                    if results.pop():
                        ok = True
                results.append(ok)
            elif name == "not":
                if n != 1:
                    fail("cfg eval error: not(...) arity mismatch.")
                results.append(not results.pop())
            else:
                fail("cfg eval error: unknown op '" + name + "'.")
    if todo:
        fail("cfg eval error: internal traversal did not finish.")
    if len(results) != 1:
        fail("cfg eval error: unexpected result stack size.")
    return results[0]

def cfg_matches(expr, triple, features=[], target_features=[]):
    ast = cfg_parse(expr)
    ctx = triple_to_cfg_attrs(triple, features, target_features)
    return _cfg_eval(ast, ctx)

def cfg_matches_expr_for_triples(expr, triples, features=[], target_features=[]):
    cfg_attrs = [triple_to_cfg_attrs(triple, features, target_features) for triple in triples]
    return cfg_matches_expr_for_cfg_attrs(cfg_parse(expr), cfg_attrs, features, target_features)

def cfg_matches_expr_for_cfg_attrs(expr, cfg_attrs, features=[], target_features=[]):
    return cfg_matches_ast_for_triples(cfg_parse(expr), cfg_attrs)

def cfg_matches_ast_for_triples(ast, cfg_attrs):
    return [cfg_attr["_triple"] for cfg_attr in cfg_attrs if _cfg_eval(ast, cfg_attr)]
