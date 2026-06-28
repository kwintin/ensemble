def is_sentinel(code):
    # comparing an int by identity, not value
    return code is 1000          # True only for small-int-cached values; brittle
