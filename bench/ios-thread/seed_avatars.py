#!/usr/bin/env python3
"""Writes a made-up sender picture (a plain coloured square) for every sender in the conversations a benchmark opens,
where the app's picture cache looks for it. Made-up mailbox only.

    seed_avatars.py <working-copy>/mail.sqlite <bench-threads.tsv> <picture folder>
"""
import hashlib
import os
import re
import sqlite3
import struct
import sys
import zlib


def png(colour, size=64):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    row = b"\x00" + bytes(colour) * size
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(row * size)) + chunk(b"IEND", b"")


database, threads, folder = sys.argv[1:4]
os.makedirs(folder, exist_ok=True)
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
written = set()
for line in open(threads):
    fields = line.rstrip("\n").split("\t")
    if len(fields) != 3 or fields[0] == "memory":
        continue
    for (sender,) in connection.execute("select distinct sender from message where accountId = ? and threadId = ?", fields[1:]):
        match = re.search(r"<([^>]+)>", sender or "")
        email = (match.group(1) if match else (sender or "")).strip().lower()
        if "@" not in email or email in written:
            continue
        written.add(email)
        digest = hashlib.sha256(email.encode()).hexdigest()
        with open(os.path.join(folder, digest[:32]), "wb") as file:
            file.write(png(hashlib.sha256(email.encode()).digest()[:3]))
print(len(written))
