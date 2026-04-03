#!/usr/bin/env python3
"""
Envato Elements WordPress Plugin Link Scraper
==============================================
Scrape tất cả link plugin WordPress từ:
https://elements.envato.com/fr/wordpress/plugins

Lặp qua tất cả các page cho đến khi hết, ghi output vào file.

Cài đặt thư viện cần thiết:
    pip install requests beautifulsoup4 lxml

Chạy:
    python envato_plugin_scraper.py
"""

import requests
from bs4 import BeautifulSoup
import time
import re

# ── Config ──────────────────────────────────────────────────────────────────
BASE_URL = "https://elements.envato.com/fr/wordpress/plugins"
OUTPUT_FILE = "envato_plugin_links.txt"
DELAY_BETWEEN_REQUESTS = 1.5  # giây – tránh bị rate-limit
MAX_RETRIES = 3

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "fr-FR,fr;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
    "Referer": "https://elements.envato.com/",
    "DNT": "1",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
}


# ── Helpers ─────────────────────────────────────────────────────────────────
def build_url(page: int) -> str:
    """Tạo URL cho từng page."""
    if page == 1:
        return BASE_URL
    return f"{BASE_URL}/pg-{page}"


def fetch_page(session: requests.Session, url: str):
    """GET một page, retry nếu thất bại."""
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(url, headers=HEADERS, timeout=30)
            if resp.status_code == 200:
                return resp
            if resp.status_code == 404:
                return None
            print(f"  [!] HTTP {resp.status_code} – retry {attempt}/{MAX_RETRIES}")
        except requests.RequestException as e:
            print(f"  [!] Request error: {e} – retry {attempt}/{MAX_RETRIES}")
        time.sleep(DELAY_BETWEEN_REQUESTS)
    return None


def extract_plugin_links(html: str) -> list:
    """
    Trích xuất tất cả link plugin từ HTML của một page.

    Envato Elements dùng thẻ <a> với href dạng:
        /fr/<slug>-XXXXXXX  (item slug kết thúc bằng mã ID viết hoa)
    hoặc:
        /fr/wordpress/plugins/<slug>
    """
    soup = BeautifulSoup(html, "lxml")
    links = set()

    for a_tag in soup.find_all("a", href=True):
        href = a_tag["href"].strip()

        # ── Pattern 1: Specific plugin path ──
        # /fr/wordpress/plugins/<slug-with-ID>
        if re.match(r"^/fr/wordpress/plugins/[a-zA-Z0-9][\w-]+-[A-Z0-9]{5,}$", href):
            full_url = f"https://elements.envato.com{href}"
            links.add(full_url)
            continue

        # ── Pattern 2: Full URL dạng trên ──
        if re.match(
            r"^https?://elements\.envato\.com/fr/wordpress/plugins/[a-zA-Z0-9][\w-]+-[A-Z0-9]{5,}$",
            href,
        ):
            links.add(href)
            continue

        # ── Pattern 3: Item link dạng /fr/<slug>-<ID> (general Envato item) ──
        # Envato thường dùng link kiểu /fr/item-name-ABCD123
        if re.match(r"^/fr/[\w-]+-[A-Z0-9]{5,}$", href):
            full_url = f"https://elements.envato.com{href}"
            links.add(full_url)
            continue

    # ── Fallback: pattern rộng hơn nếu chưa bắt được gì ──
    if not links:
        for a_tag in soup.find_all("a", href=True):
            href = a_tag["href"].strip()
            if "/wordpress/plugins/" in href and "/pg-" not in href:
                path = href.rstrip("/")
                if path.endswith("/plugins") or path.endswith("/wordpress"):
                    continue
                slug = path.rsplit("/", 1)[-1]
                if "-" in slug and len(slug) > 5:
                    if href.startswith("http"):
                        links.add(href)
                    else:
                        links.add(f"https://elements.envato.com{href}")

    return sorted(links)


def detect_last_page(html: str, current_page: int) -> bool:
    """
    Kiểm tra xem đây có phải page cuối không bằng nhiều cách:
    1. Không có link next page
    2. Không có nút "next" / "suivant"
    3. Kiểm tra pagination element
    """
    soup = BeautifulSoup(html, "lxml")
    next_pg = current_page + 1

    # Cách 1: Tìm link /pg-{next}
    for a_tag in soup.find_all("a", href=True):
        if f"/pg-{next_pg}" in a_tag["href"]:
            return False

    # Cách 2: Tìm nút next/suivant (Envato dùng tiếng Pháp)
    for a_tag in soup.find_all("a"):
        text = a_tag.get_text(strip=True).lower()
        aria = (a_tag.get("aria-label") or "").lower()
        if "next" in text or "suivant" in text or "next" in aria:
            return False

    return True


# ── Main ────────────────────────────────────────────────────────────────────
def main():
    all_links = []
    seen = set()
    page = 1
    empty_streak = 0  # đếm số page liên tiếp không có link mới

    session = requests.Session()

    print("=" * 60)
    print("  Envato Elements – WordPress Plugin Scraper")
    print("=" * 60)

    while True:
        url = build_url(page)
        print(f"\n[Page {page}] {url}")

        resp = fetch_page(session, url)

        if resp is None:
            print(f"  → Không thể truy cập page {page}. Dừng lại.")
            break

        plugin_links = extract_plugin_links(resp.text)

        # Lọc trùng
        new_links = [link for link in plugin_links if link not in seen]
        for link in new_links:
            seen.add(link)
            all_links.append(link)

        print(f"  → Tìm thấy {len(plugin_links)} link ({len(new_links)} mới)")

        # Dừng nếu 2 page liên tiếp không có link mới
        if len(new_links) == 0:
            empty_streak += 1
            if empty_streak >= 2:
                print("  → 2 page liên tiếp không có link mới. Dừng.")
                break
        else:
            empty_streak = 0

        # Kiểm tra page cuối
        if detect_last_page(resp.text, page):
            print(f"\n  ✓ Đây là page cuối cùng (page {page}).")
            break

        page += 1
        time.sleep(DELAY_BETWEEN_REQUESTS)

    # ── Ghi ra file ──
    print(f"\n{'=' * 60}")
    print(f"  Tổng cộng: {len(all_links)} plugin links")
    print(f"  Ghi vào  : {OUTPUT_FILE}")
    print(f"{'=' * 60}")

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(all_links))
        if all_links:
            f.write("\n")

    print(f"\n  ✓ Hoàn tất! Kiểm tra file: {OUTPUT_FILE}\n")


if __name__ == "__main__":
    main()