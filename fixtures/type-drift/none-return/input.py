def find(items, target):
    for it in items:
        if it == target:
            return it
    # falls through -> returns None implicitly

def use(items, target):
    result = find(items, target)
    return result.upper()      # AttributeError when find returns None
