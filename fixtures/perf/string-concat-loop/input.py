def join_rows(rows):
    s = ""
    for r in rows:
        s += str(r) + "\n"   # quadratic string building
    return s
