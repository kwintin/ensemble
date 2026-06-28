import threading

count = 0

def worker():
    global count
    for _ in range(100000):
        count += 1          # read-modify-write with no lock -> lost updates

def run():
    ts = [threading.Thread(target=worker) for _ in range(8)]
    for t in ts: t.start()
    for t in ts: t.join()
    return count
