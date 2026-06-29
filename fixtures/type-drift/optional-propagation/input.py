def find_user(db, uid):
    return db.get(uid)            # returns None when uid is absent

def display_name(db, uid):
    user = find_user(db, uid)     # Optional[dict] flows through unchecked
    return format_name(user)

def format_name(user):
    return user["first"] + " " + user["last"]   # TypeError when user is None
