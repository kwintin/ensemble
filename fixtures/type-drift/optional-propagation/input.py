def find_user(db, uid):
    return db.get(uid)

def display_name(db, uid):
    user = find_user(db, uid)
    return format_name(user)

def format_name(user):
    return user["first"] + " " + user["last"]
