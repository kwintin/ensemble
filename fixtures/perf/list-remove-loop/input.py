def drop_inactive(users):
    for u in users[:]:          # iterate a copy so removal is "safe"
        if not u.active:
            users.remove(u)     # list.remove is O(n) -> overall O(n^2)
    return users
