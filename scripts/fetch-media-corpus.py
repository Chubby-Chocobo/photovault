"""Download the media corpus listed in the test manifest and verify every file's SHA-256.

Usage: python3 -I scripts/fetch-media-corpus.py <directory>
Files already present with the right checksum are kept, so a restored cache costs nothing.
"""
import hashlib
import json
import os
import sys
import urllib.request

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "PhotoVaultPhotosTests",
                        "Fixtures", "MediaCorpus", "manifest.json")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


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
        partial = path + ".part"
        try:
            urllib.request.urlretrieve(entry["url"], partial)
        except Exception as error:
            print(f"FAILED  {entry['file']}: {error}")
            failures += 1
            continue
        if sha256(partial) != entry["sha256"]:
            os.remove(partial)
            print(f"FAILED  {entry['file']}: checksum differs from the manifest")
            failures += 1
            continue
        os.replace(partial, path)
        print(f"fetched {entry['file']}")
    if failures:
        sys.exit(f"{failures} file(s) could not be fetched")


if __name__ == "__main__":
    main()
