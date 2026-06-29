import requests

def fetch_preview(url):
    # url comes from a user-submitted webhook field; no host allowlist
    return requests.get(url, timeout=5).text   # SSRF: can reach 169.254.169.254, localhost, internal hosts
