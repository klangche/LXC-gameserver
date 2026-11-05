#!/usr/bin/env python3
"""Build games/<game>/install-server-commands.sh from lib/ and games/<game>/profile.conf.

    python3 tools/build-commands.py          regenerate all games
    python3 tools/build-commands.py --check  exit 1 if a generated file is out of date (CI)

install.sh downloads one self-contained install-server-commands.sh per game, so the shared
code in lib/ is inlined here instead of being copied by hand into six files.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "lib" / "installer.sh"
INLINE = re.compile(r"^#@INLINE (\S+)$", re.M)
DELIMS = re.compile(r"<<'(\w+)'")


def build(game_dir):
    game = game_dir.name
    profile = (game_dir / "profile.conf").read_text().rstrip("\n")
    if not re.search(r"^GAME=%s$" % re.escape(game), profile, re.M):
        raise SystemExit("%s/profile.conf: GAME must be %s" % (game_dir, game))
    text = TEMPLATE.read_text()
    delims = {d for d in DELIMS.findall(text) if d.startswith("GS_EOF")}

    def inline(match):
        body = (ROOT / match.group(1)).read_text().rstrip("\n")
        for delim in delims:
            if re.search(r"^%s$" % delim, body, re.M):
                raise SystemExit("%s contains the heredoc delimiter %s" % (match.group(1), delim))
        return body

    text = INLINE.sub(inline, text)
    return text.replace("@@PROFILE@@", profile).replace("@@GAME@@", game)


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for game_dir in sorted((ROOT / "games").iterdir()):
        if not (game_dir / "profile.conf").is_file():
            continue
        out = game_dir / "install-server-commands.sh"
        text = build(game_dir)
        if out.exists() and out.read_text() == text:
            continue
        if check:
            stale.append(str(out.relative_to(ROOT)))
        else:
            out.write_text(text)
            out.chmod(0o755)
            print("wrote", out.relative_to(ROOT))
    if stale:
        print("Out of date (run: python3 tools/build-commands.py):")
        for path in stale:
            print("  " + path)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
