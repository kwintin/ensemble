def pairwise_sums(a):
    out = []
    for i in range(len(a)):
        out.append(a[i] + a[i + 1])
    return out
