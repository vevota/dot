#!/usr/bin/env python3
import os, sys, re, json, sqlite3
from urllib.request import urlopen, Request
from urllib.error import HTTPError

M = "/mnt/melody/media/Music"
LDB = "/var/lib/lidarr/lidarr.db"
COVERS = {"cover.jpg","cover.png","folder.jpg","front.jpg","cover.jpeg","folder.png","front.png"}

print("Scanning for albums without covers...")
missing = []
for a in sorted(os.listdir(M)):
    ad = os.path.join(M, a)
    if not os.path.isdir(ad): continue
    for al in sorted(os.listdir(ad)):
        ald = os.path.join(ad, al)
        if not os.path.isdir(ald): continue
        found = False
        for f in os.listdir(ald):
            if os.path.isfile(os.path.join(ald, f)) and f.lower() in COVERS:
                found = True; break
        if not found:
            missing.append((a, al, ald))
print("  " + str(len(missing)) + " albums need covers")

print("Loading Lidarr cover URLs...")
conn = sqlite3.connect(LDB)
c = conn.cursor()
c.execute("""
    SELECT am.Name, al.Title, al.Images
    FROM Albums al
    JOIN ArtistMetadata am ON al.ArtistMetadataId = am.Id
""")
rows = c.fetchall()
conn.close()

cover_urls = {}
for artist, title, images_json in rows:
    if not images_json: continue
    try:
        images = json.loads(images_json)
    except: continue
    cover_url = None
    for img in images:
        if img.get("coverType") == "cover":
            cover_url = img.get("url")
            break
    if cover_url:
        k1 = (artist.strip().lower(), title.strip().lower())
        cover_urls[k1] = cover_url
        ct = re.sub(r"\s*\(\d{4}\).*$", "", title).strip().lower()
        if ct != title.strip().lower():
            cover_urls[(artist.strip().lower(), ct)] = cover_url
print("  " + str(len(cover_urls)) + " cover URLs indexed")

dl = 0
nf = 0
skip = 0
for artist, album, ald in missing:
    k1 = (artist.lower(), album.lower())
    k2 = (artist.lower(), re.sub(r"\s*\(\d{4}\).*$", "", album).strip().lower())
    url = cover_urls.get(k1) or cover_urls.get(k2)
    if not url:
        nf += 1
        continue
    dest = os.path.join(ald, "cover.jpg")
    if os.path.exists(dest):
        skip += 1
        continue
    try:
        req = Request(url, headers={"User-Agent": "MelodyBot/1.0"})
        resp = urlopen(req, timeout=15)
        data = resp.read()
        if len(data) > 500:
            with open(dest, "wb") as f: f.write(data)
            sz = os.path.getsize(dest)
            print("OK " + artist + " / " + album + " (" + str(sz//1024) + "KB)")
            dl += 1
        else:
            print("SKIP " + artist + " / " + album + " (too small)")
            nf += 1
    except Exception as e:
        print("FAIL " + artist + " / " + album + " (" + str(e)[:50] + ")")
        nf += 1

print("\nDone: " + str(dl) + " downloaded, " + str(nf) + " not found/failed, " + str(skip) + " skipped")
