def pairwise_sums(a):
    out = []
    for i in range(len(a)):
        out.append(a[i] + a[i + 1])   # a[i+1] runs past the end on the last i
    return out
