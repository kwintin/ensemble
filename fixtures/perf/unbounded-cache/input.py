_cache = {}

def render(template_id, data):
    key = (template_id, repr(data))   # data varies every call -> a new key every time
    if key not in _cache:
        _cache[key] = _compile(template_id, data)   # _cache grows without bound -> memory leak
    return _cache[key]
