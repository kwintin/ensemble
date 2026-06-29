import threading

_cache = {}
_lock = threading.Lock()

def get_or_build(key):
    with _lock:
        hit = key in _cache        # lock released right after the check
    if not hit:
        val = expensive_build(key) # two threads can both reach here -> double build / lost write
        with _lock:
            _cache[key] = val
    return _cache[key]
