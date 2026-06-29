def common(a, b):
    out = []
    for x in a:
        if x in b:
            out.append(x)
    return out
