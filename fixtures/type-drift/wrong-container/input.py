def index_by_id(records: dict) -> dict:
    return {r["id"]: r for r in records}     # iterating a dict yields KEYS, not records

def build(rows):
    # rows is a list, but index_by_id is annotated/used as if given a dict
    return index_by_id(rows)
