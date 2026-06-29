def drop_inactive(users):
    for u in users[:]:
        if not u.active:
            users.remove(u)
    return users
