def _parse_version(v):
    # Drop prerelease/build if present (e.g., 1.2.3-alpha+001)
    v = v.split("-", 1)[0].split("+", 1)[0]
    parts = v.split(".")
    # Pad to 3 components
    nums = []
    for i in range(3):
        if i < len(parts) and parts[i] != "":
            # Allow leading zeros; treat non-numeric as 0
            #try:
            nums.append(int(parts[i]))
            #except:
            #    nums.append(0)
        else:
            nums.append(0)
    # major, minor, patch
    return tuple(nums)

def _cmp(a, b):
    for i in range(3):
        if a[i] != b[i]:
            return -1 if a[i] < b[i] else 1
    return 0

def _cargo_default_upper_bound(base):
    # Implements semver caret upper bound:
    # increment the leftmost NON-ZERO component of the *specified* version,
    # zeroing the rest; if all zero, bump patch.
    # Examples:
    #   ^1.2.3 -> <2.0.0
    #   ^1.2   -> <2.0.0
    #   ^0.2.3 -> <0.3.0
    #   ^0.0.3 -> <0.0.4
    major, minor, patch = base
    if major != 0:
        return (major + 1, 0, 0)
    if minor != 0:
        return (0, minor + 1, 0)
    if patch != 0:
        return (0, 0, patch + 1)
    return (1, 0, 0)

def _range_for_caret(req_ver_tuple):
    low = req_ver_tuple
    high = _cargo_default_upper_bound(req_ver_tuple)
    return (low, high)

def _satisfies_caret(req_tuple, ver_tuple):
    low, high = _range_for_caret(req_tuple)
    return _cmp(ver_tuple, low) >= 0 and _cmp(ver_tuple, high) < 0

def _satisfies_caret_or_bare(req_tuple, ver_tuple):
    lo = req_tuple
    hi = _cargo_default_upper_bound(req_tuple)
    return _cmp(ver_tuple, lo) >= 0 and _cmp(ver_tuple, hi) < 0

def _parse_comparator_req(req):
    for op in (">=", ">", "=", "<=", "<"):
        if req.startswith(op):
            return op, _parse_version(req[len(op):])

    return None

def _satisfies_comparator(op, rhs_tuple, ver_tuple):
    c = _cmp(ver_tuple, rhs_tuple)
    if op == "<":  return c < 0
    if op == "<=": return c <= 0
    if op == ">":  return c > 0
    if op == ">=": return c >= 0
    if op == "=": return c == 0
    return False

def select_matching_version(req, versions):
    """
    Supports:
      - caret or bare default: "^X.Y.Z", "X.Y", "0", etc. (Cargo semantics, incl. ^0 == 0)
      - simple comparators: "<X.Y.Z", "<=X.Y.Z", ">X.Y.Z", ">=X.Y.Z"
    Returns highest matching version string, or None.
    """
    # 1) Comparator?
    cmp_req = _parse_comparator_req(req)
    if cmp_req:
        op, rhs = cmp_req
        matches = []
        for v in versions:
            vt = _parse_version(v)
            if _satisfies_comparator(op, rhs, vt):
                matches.append((vt, v))
        if not matches:
            return None
        best = matches[0]
        for cand in matches[1:]:
            if _cmp(cand[0], best[0]) > 0:
                best = cand
        return best[1]

    # 2) Caret or bare (treated the same per Cargo)
    base = _parse_version(req.removeprefix("^"))

    matches = []
    for v in versions:
        vt = _parse_version(v)
        if _satisfies_caret_or_bare(base, vt):
            matches.append((vt, v))
    if not matches:
        return None
    best = matches[0]
    for cand in matches[1:]:
        if _cmp(cand[0], best[0]) > 0:
            best = cand
    return best[1]
