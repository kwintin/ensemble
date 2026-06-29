def first_name(users_by_id):
    for u in users_by_id:
        return u["name"]

def greet(users_by_id):
    return "Hi " + first_name(users_by_id)
