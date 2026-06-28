def average(xs):
    return sum(xs) / len(xs)   # planted bug: ZeroDivisionError on empty list
