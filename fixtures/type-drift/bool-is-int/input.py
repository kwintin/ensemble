def set_quantity(qty):
    if not isinstance(qty, int):
        raise TypeError("qty must be an int")
    return qty
