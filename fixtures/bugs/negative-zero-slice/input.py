def last_n(items, n):
    # intended: return the last n items; for n == 0 we expect [] (no items)
    return items[-n:]      # items[-0:] == items[0:] == the WHOLE list, not []
