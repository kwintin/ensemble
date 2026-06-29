import threading

lock_a = threading.Lock()
lock_b = threading.Lock()

def transfer(x, y):
    with lock_a:
        with lock_b:
            x.debit(); y.credit()

def refund(x, y):
    with lock_b:                  # acquires B then A -- opposite order from transfer
        with lock_a:
            x.credit(); y.debit()
