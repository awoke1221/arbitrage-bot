import requests
from bs4 import BeautifulSoup
import re
import csv
import random
import time
from urllib.parse import urljoin

# -------------------------
# SETTINGS
# -------------------------
BASE_URL = "https://www.amharabank.com.et/"   # Change this to your target website
MAX_PAGES = 50                     # Limit number of pages to avoid infinite crawling
OUTPUT_FILE = "emails.csv"

# List of User-Agents to rotate (more can be added)
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0 Safari/537.36",
]

# Regex pattern for email
EMAIL_REGEX = r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"

# -------------------------
# FUNCTIONS
# -------------------------
def get_headers():
    """Return random headers with rotating User-Agent."""
    return {"User-Agent": random.choice(USER_AGENTS)}

def extract_emails(text):
    """Find all emails in text."""
    return re.findall(EMAIL_REGEX, text)

def crawl(base_url, max_pages=50):
    """Crawl a website for emails."""
    visited = set()
    to_visit = [base_url]
    emails = set()

    while to_visit and len(visited) < max_pages:
        url = to_visit.pop()
        if url in visited:
            continue
        visited.add(url)

        try:
            print(f"[INFO] Visiting: {url}")
            response = requests.get(url, headers=get_headers(), timeout=10)
            if response.status_code != 200:
                print(f"[WARN] Skipping {url}, status {response.status_code}")
                continue

            soup = BeautifulSoup(response.text, "html.parser")

            # Extract emails
            page_emails = extract_emails(response.text)
            if page_emails:
                print(f"[FOUND] Emails on {url}: {page_emails}")
                emails.update(page_emails)

            # Extract links for crawling
            for a in soup.find_all("a", href=True):
                link = urljoin(url, a["href"])
                if base_url in link and link not in visited:
                    to_visit.append(link)

            # Sleep to avoid detection
            time.sleep(random.uniform(1, 3))

        except Exception as e:
            print(f"[ERROR] Failed {url}: {e}")

    return emails

def save_to_csv(emails, filename):
    """Save emails into a CSV file."""
    with open(filename, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Email"])
        for email in emails:
            writer.writerow([email])
    print(f"[DONE] Saved {len(emails)} emails to {filename}")

# -------------------------
# MAIN
# -------------------------
if __name__ == "__main__":
    found_emails = crawl(BASE_URL, MAX_PAGES)
    save_to_csv(found_emails, OUTPUT_FILE)
