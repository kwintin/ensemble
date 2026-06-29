def round_money(amount):
    # round() uses banker's rounding (half-to-even): round(2.675, 2) -> 2.67, round(0.5) -> 0
    # currency expects half-UP, so customers are under/over-charged by a cent
    return round(amount, 2)
