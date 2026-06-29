import threading

_cache = {}
_lock = threading.Lock()

def get_or_build(key):
    with _lock:
        hit = key in _cache
    if not hit:
        val = expensive_build(key)
        with _lock:
            _cache[key] = val
    return _cache[key]
