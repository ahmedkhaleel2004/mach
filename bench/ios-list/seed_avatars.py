"""Gives every sender in the made-up mailbox a made-up picture, in a folder the benchmark app is pointed at.

Offline, the app never downloads pictures, so without this the list only ever draws initials and the picture
caches stay empty. Each picture is a 160 x 160 PNG of coloured blocks, about the size of a real profile picture.

    python3 bench/ios-list/seed_avatars.py <mail.sqlite of a working copy> <folder> (passed to the app as BLITZ_AVATAR_DIR)
"""
import hashlib, os, random, sqlite3, struct, sys, zlib

database, folder = sys.argv[1], sys.argv[2]
os.makedirs(folder, exist_ok=True)


def png(seed):
    rng = random.Random(seed)
    side, block = 160, 8
    colours = [[(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(side // block)] for _ in range(side // block)]
    rows = bytearray()
    for y in range(side):
        rows.append(0)
        for x in range(side):
            r, g, b = colours[y // block][x // block]
            noise = rng.randrange(-1, 2) if rng.random() < 0.5 else 0
            rows += bytes((max(0, min(255, r + noise)), max(0, min(255, g + noise)), max(0, min(255, b + noise))))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")


emails = [row[0] for row in sqlite3.connect(database).execute("select distinct lower(avatarEmail) from thread where avatarEmail like '%@%'")]
total = 0
for email in emails:
    data = png(email)
    total += len(data)
    with open(os.path.join(folder, hashlib.sha256(email.encode()).hexdigest()[:32]), "wb") as out:
        out.write(data)
print(f"{len(emails)} pictures, {total / max(1, len(emails)) / 1024:.1f} KB each on average, in {folder}")
