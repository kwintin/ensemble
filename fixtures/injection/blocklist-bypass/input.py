import re

def sanitize_html(s):
    # strips <script> tags, then trusts the rest as safe HTML
    s = re.sub(r"(?i)<script.*?>.*?</script>", "", s)
    return s          # <img src=x onerror=alert(1)>, <svg onload=...> etc. still pass
