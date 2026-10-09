"""Compares two screenshots pixel by pixel. Exit 0 when every pixel is the same."""
import sys
from PIL import Image, ImageChops

before, after = Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")
name = sys.argv[1].rsplit("/", 1)[-1]
if before.size != after.size:
    print(f"DIFFERENT {name}: sizes {before.size} and {after.size}")
    sys.exit(1)
box = ImageChops.difference(before, after).getbbox()
if box is None:
    print(f"same      {name} (same pixels, different file bytes)")
    sys.exit(0)
changed = sum(1 for pixel in ImageChops.difference(before, after).crop(box).getdata() if pixel != (0, 0, 0))
print(f"DIFFERENT {name}: {changed} pixels, inside {box}")
sys.exit(1)
