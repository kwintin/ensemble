def split_evenly(total_cents, parties):
    # integer division silently drops the remainder cents
    return total_cents // parties      # 100 // 3 -> 33, loses 1 cent
