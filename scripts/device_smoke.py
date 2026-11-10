#!/usr/bin/env python3
"""Small HarmonyOS UI smoke-test helper for the DeckCraft port.

Keeps the repetitive hdc plumbing out of the verification loop:

  python scripts/device_smoke.py shot <name>          # screenshot -> .verify/<name>.jpeg
  python scripts/device_smoke.py tap <x> <y>          # uitest click (physical pixels)
  python scripts/device_smoke.py double <x> <y>       # uitest double click
  python scripts/device_smoke.py text <ascii>         # uitest text (ASCII only!)
  python scripts/device_smoke.py swipe <x1> <y1> <x2> <y2>
  python scripts/device_smoke.py key <Back|Home|...>
  python scripts/device_smoke.py restart              # force-stop + aa start
  python scripts/device_smoke.py lang <zh-Hans|en-US> # set system language param
  python scripts/device_smoke.py contact <n1> <n2> …  # contact sheet of shots

Notes learned the hard way:
 * `snapshot_display` only accepts a `.jpeg` suffix.
 * `hdc file recv /data/... <local>` needs a **relative** local path; absolute
   Windows paths get appended to the cwd and fail with `operation not permitted`.
   Calling hdc.exe directly from Python (no MSYS bash) avoids path translation.
 * `uitest uiInput text` only injects ASCII; non-ASCII silently does nothing.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys

HDC = r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
DEVICE = os.environ.get("DC_DEVICE", "46G0225429001073")
BUNDLE = "io.github.shaliuxin.deckcraft.hmos"
ROOT = pathlib.Path(__file__).resolve().parents[1]
VERIFY = ROOT / ".verify"
VERIFY.mkdir(exist_ok=True)


def run(args: list[str], cwd: pathlib.Path | None = None) -> str:
    proc = subprocess.run(
        [HDC, "-t", DEVICE, *args],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        print(f"[hdc rc={proc.returncode}] {out.strip()[:400]}")
    return out.strip()


def shot(name: str) -> None:
    remote = f"/data/local/tmp/dc_{name}.jpeg"
    run(["shell", "snapshot_display", "-f", remote])
    out = run(["file", "recv", remote, f"{name}.jpeg"], cwd=VERIFY)
    target = VERIFY / f"{name}.jpeg"
    print(f"shot {name}: {target.stat().st_size} bytes" if target.exists() else f"shot {name} FAILED: {out}")


def contact(names: list[str]) -> None:
    from PIL import Image, ImageDraw

    thumbs: list[tuple[str, Image.Image]] = []
    for name in names:
        path = VERIFY / f"{name}.jpeg"
        if not path.exists():
            print("missing", path)
            continue
        img = Image.open(path).convert("RGB")
        img.thumbnail((620, 404))
        thumbs.append((name, img))
    if not thumbs:
        return
    cols = 2
    rows = (len(thumbs) + cols - 1) // cols
    cell_w, cell_h = 640, 440
    sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), (245, 245, 245))
    draw = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(thumbs):
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        draw.text((x + 8, y + 6), name, fill=(20, 20, 20))
        sheet.paste(img, (x + 10, y + 26))
    out = VERIFY / "contact.jpeg"
    sheet.save(out, quality=88)
    print(f"contact sheet: {out} ({len(thumbs)} shots)")


def main(argv: list[str]) -> None:
    if not argv:
        print(__doc__)
        return
    cmd, *args = argv
    if cmd == "shot":
        shot(args[0])
    elif cmd == "tap":
        print(run(["shell", "uitest", "uiInput", "click", args[0], args[1]]))
    elif cmd == "double":
        print(run(["shell", "uitest", "uiInput", "doubleClick", args[0], args[1]]))
    elif cmd == "text":
        print(run(["shell", "uitest", "uiInput", "text", args[0]]))
    elif cmd == "swipe":
        print(run(["shell", "uitest", "uiInput", "swipe", *args[:4]]))
    elif cmd == "key":
        print(run(["shell", "uitest", "uiInput", "keyEvent", args[0]]))
    elif cmd == "restart":
        run(["shell", "aa", "force-stop", BUNDLE])
        print(run(["shell", "aa", "start", "-b", BUNDLE, "-a", "EntryAbility", "-m", "entry"]))
    elif cmd == "lang":
        print(run(["shell", "param", "set", "persist.global.language", args[0]]))
        print(run(["shell", "param", "get", "persist.global.language"]))
    elif cmd == "contact":
        contact(args)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
