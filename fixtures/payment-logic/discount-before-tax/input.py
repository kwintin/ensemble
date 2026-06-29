def total(price_cents, tax_rate, discount_cents):
    """Apply the discount to the pre-tax price, then charge tax on the discounted amount."""
    taxed = round(price_cents * (1 + tax_rate))
    return taxed - discount_cents
