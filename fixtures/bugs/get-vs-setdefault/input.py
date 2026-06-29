def group(pairs):
    out = {}
    for key, val in pairs:
        out.get(key, []).append(val)
    return out
