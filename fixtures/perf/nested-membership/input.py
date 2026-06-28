def common(a, b):
    out = []
    for x in a:
        if x in b:        # b is a list -> O(n) membership inside an O(n) loop
            out.append(x)
    return out
