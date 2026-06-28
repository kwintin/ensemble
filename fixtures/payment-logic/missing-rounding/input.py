def charge_with_tax(subtotal_cents):
    tax = subtotal_cents * 0.0825     # fractional cents, never rounded
    return subtotal_cents + tax        # non-integer cents charged
