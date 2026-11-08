#!/usr/bin/env python3
# Hjälpverktyg för auto-update. Skriver ut ett värde eller avslutar med kod 1.
#   gsquery.py a2s HOST PORT[,PORT...]   antal spelare via Steam A2S_INFO
#   gsquery.py steam-latest APPID        senaste public-build (api.steamcmd.net)
#   gsquery.py mc-latest                 senaste Minecraft release (Mojang)
import json
import socket
import sys
import urllib.request


def a2s_players(host, port, timeout=3.0):
    req = b"\xff\xff\xff\xffTSource Engine Query\x00"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(req, (host, port))
        data, _ = s.recvfrom(4096)
        # Servern kan svara med en challenge som ska skickas tillbaka
        if len(data) >= 9 and data[4] == 0x41:
            s.sendto(req + data[5:9], (host, port))
            data, _ = s.recvfrom(4096)
    finally:
        s.close()
    if len(data) < 6 or data[4] != 0x49:
        raise ValueError("unexpected A2S reply")
    pos = 6  # header (4) + typ (1) + protokoll (1)
    for _ in range(4):  # name, map, folder, game
        pos = data.index(b"\x00", pos) + 1
    pos += 2  # app id (short)
    return data[pos]


def find_buildid(node):
    if isinstance(node, dict):
        pub = node.get("branches", {}).get("public") if isinstance(node.get("branches"), dict) else None
        if isinstance(pub, dict) and "buildid" in pub:
            return str(pub["buildid"])
        for value in node.values():
            found = find_buildid(value)
            if found:
                return found
    return None


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "lxc-gameserver-auto-update"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def main(argv):
    if len(argv) >= 3 and argv[0] == "a2s":
        for port in argv[2].split(","):
            try:
                print(a2s_players(argv[1], int(port)))
                return 0
            except (OSError, ValueError, IndexError):
                continue
        return 1
    if len(argv) == 2 and argv[0] == "steam-latest":
        build = find_buildid(get_json("https://api.steamcmd.net/v1/info/" + argv[1]))
        if build:
            print(build)
            return 0
        return 1
    if len(argv) == 1 and argv[0] == "mc-latest":
        print(get_json("https://launchermeta.mojang.com/mc/game/version_manifest.json")["latest"]["release"])
        return 0
    print("usage: gsquery.py a2s HOST PORTS | steam-latest APPID | mc-latest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # nätverksfel osv.
        print("gsquery: %s" % exc, file=sys.stderr)
        sys.exit(1)
