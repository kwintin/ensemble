def total(price_cents, tax_rate, discount_cents):
    taxed = round(price_cents * (1 + tax_rate))
    return taxed - discount_cents
