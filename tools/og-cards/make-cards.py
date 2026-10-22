#!/usr/bin/env python3
"""Make a 1200x627 link preview card for each published post.

Usage: python3 tools/og-cards/make-cards.py
Writes static/images/og/<post file name>.png. Needs Google Chrome.
"""
import html
import pathlib
import subprocess
import tempfile
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TEMPLATE = (pathlib.Path(__file__).parent / "card.html").read_text()


def front_matter(path):
    text = path.read_text()
    _, fm, _ = text.split("+++", 2)
    return tomllib.loads(fm)


def main():
    out_dir = ROOT / "static" / "images" / "og"
    out_dir.mkdir(parents=True, exist_ok=True)
    for post in sorted((ROOT / "content" / "posts").glob("*.md")):
        fm = front_matter(post)
        if fm.get("draft", False):
            continue
        # Keep hyphenated words such as "Multi-Node" on one line.
        words = [f'<span class="nowrap">{html.escape(w)}</span>' if "-" in w else html.escape(w)
                 for w in fm["title"].split()]
        page = TEMPLATE.replace("{{TITLE}}", " ".join(words))
        with tempfile.TemporaryDirectory() as tmp:
            card = pathlib.Path(tmp) / "card.html"
            card.write_text(page)
            out = out_dir / f"{post.stem}.png"
            subprocess.run(
                [CHROME, "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                 "--virtual-time-budget=3000", "--window-size=1200,627",
                 f"--screenshot={out}", card.as_uri()],
                check=True, capture_output=True)
            print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
