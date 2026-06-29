def set_quantity(qty):
    # guard meant to reject non-integers; but bool IS a subclass of int,
    # so set_quantity(True) passes and is used as quantity 1
    if not isinstance(qty, int):
        raise TypeError("qty must be an int")
    return qty
