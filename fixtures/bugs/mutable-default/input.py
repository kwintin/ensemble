def add_item(item, bucket=[]):     # mutable default shared across all calls
    bucket.append(item)
    return bucket
