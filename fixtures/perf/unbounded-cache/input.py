_cache = {}

def render(template_id, data):
    key = (template_id, repr(data))
    if key not in _cache:
        _cache[key] = _compile(template_id, data)
    return _cache[key]
