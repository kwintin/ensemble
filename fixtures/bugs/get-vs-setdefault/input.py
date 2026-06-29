def group(pairs):
    out = {}
    for key, val in pairs:
        # .get returns a NEW empty list each miss; the append is discarded
        out.get(key, []).append(val)
    return out                       # always {}
