def order_totals(orders, db):
    out = []
    for o in orders:
        items = db.query("SELECT price FROM items WHERE order_id = ?", o.id)
        out.append(sum(i.price for i in items))
    return out
