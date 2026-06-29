import threading

count = 0

def worker():
    global count
    for _ in range(100000):
        count += 1

def run():
    ts = [threading.Thread(target=worker) for _ in range(8)]
    for t in ts: t.start()
    for t in ts: t.join()
    return count
