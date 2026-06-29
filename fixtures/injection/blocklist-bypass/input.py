import re

def sanitize_html(s):
    """Remove scripts so the result is safe to embed."""
    s = re.sub(r"(?i)<script.*?>.*?</script>", "", s)
    return s
