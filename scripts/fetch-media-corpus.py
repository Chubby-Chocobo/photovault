"""Download the media corpus listed in the test manifest and verify every file's SHA-256.

Usage: python3 -I scripts/fetch-media-corpus.py <directory>
Files already present with the right checksum are kept, so a restored cache costs nothing.
Each download has a read timeout and is tried up to three times.
"""
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.request

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "PhotoVaultPhotosTests",
                        "Fixtures", "MediaCorpus", "manifest.json")
TIMEOUT_SECONDS = 60
ATTEMPTS = 3


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": "PhotoVault-test-corpus"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response, open(path, "wb") as out:
        shutil.copyfileobj(response, out, 1 << 20)


def fetch(entry, path):
    partial = path + ".part"
    error = "unknown"
    for attempt in range(1, ATTEMPTS + 1):
        try:
            download(entry["url"], partial)
            if sha256(partial) == entry["sha256"]:
                os.replace(partial, path)
                return None
            error = "checksum differs from the manifest"
        except Exception as exc:  # network errors, timeouts, HTTP errors
            error = str(exc)
        if os.path.exists(partial):
            os.remove(partial)
        if attempt < ATTEMPTS:
            time.sleep(5 * attempt)
    return error


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    target = os.path.expanduser(sys.argv[1])
    os.makedirs(target, exist_ok=True)
    failures = 0
    for entry in json.load(open(MANIFEST)):
        path = os.path.join(target, entry["file"])
        if os.path.exists(path) and sha256(path) == entry["sha256"]:
            print(f"ok      {entry['file']}")
            continue
        error = fetch(entry, path)
        if error:
            print(f"FAILED  {entry['file']}: {error}")
            failures += 1
        else:
            print(f"fetched {entry['file']}")
    if failures:
        sys.exit(f"{failures} file(s) could not be fetched")


if __name__ == "__main__":
    main()
