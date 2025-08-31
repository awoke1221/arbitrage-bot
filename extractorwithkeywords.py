from googlesearch import search
import re
import requests
from bs4 import BeautifulSoup

# Search query
query = 'site:google.com "@gmail.com" OR "@yahoo.com"'

# Regex for emails
EMAIL_REGEX = r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"

emails = set()

# Get top search results (URLs)
for url in search(query, num_results=20):
    try:
        print(f"[INFO] Visiting: {url}")
        res = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=10)
        soup = BeautifulSoup(res.text, "html.parser")
        page_text = soup.get_text()
        
        found = re.findall(EMAIL_REGEX, page_text)
        emails.update(found)
        
    except Exception as e:
        print(f"[ERROR] {url} -> {e}")

print("Emails found:", emails)
