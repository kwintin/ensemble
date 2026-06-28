def first_name(users_by_id):
    # users_by_id is a dict {id: {"name": ...}}; iterating a dict yields KEYS (ids),
    # so `u["name"]` indexes an int id -> TypeError at runtime
    for u in users_by_id:
        return u["name"]

def greet(users_by_id):
    return "Hi " + first_name(users_by_id)   # called with a real dict
