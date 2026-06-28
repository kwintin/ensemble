def parse_count(raw: str) -> int:
    return raw.strip()          # returns a str, not the annotated int

def double(raw: str) -> int:
    return parse_count(raw) * 2  # str * 2 duplicates the string, not arithmetic
