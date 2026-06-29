def charge_with_tax(subtotal_cents):
    tax = subtotal_cents * 0.0825
    return subtotal_cents + tax
