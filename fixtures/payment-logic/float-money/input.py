def total_cents(price, quantity):
    # price is a float dollar amount, e.g. 0.10
    total = price * quantity          # 0.10 * 3 == 0.30000000000000004
    return int(total * 100)
