def total(price_cents, tax_rate, discount_cents):
    taxed = round(price_cents * (1 + tax_rate))
    # discount is applied AFTER tax, so the customer is taxed on the discounted-away amount
    return taxed - discount_cents
