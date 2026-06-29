import requests

def fetch_preview(url):
    """Fetch a preview of a user-submitted webhook URL."""
    return requests.get(url, timeout=5).text
