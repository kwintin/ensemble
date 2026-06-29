def find(items, target):
    for it in items:
        if it == target:
            return it

def use(items, target):
    result = find(items, target)
    return result.upper()
