"""Clean screenshots of every page: no button fuzzer, no stray toasts, the window as a player sees it.

    tools\\.venv\\Scripts\\python.exe -B tools\\harness\\gallery.py OUTDIR [--addon DIR]

Writes <page>-empty.png (launch morning) and <page>.png (after a raid night) for the GM. Set
GF_RENDER_SCALE=1.33 to match the owner's screen. --addon renders another copy of the addon, such
as an old version for a before and after.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run as R  # noqa: E402

PAGES = ("home", "feed", "raids", "softres", "loot", "attendance", "buffs", "roster", "fame", "tradies", "settings")


def main(argv):
    out = os.path.abspath(argv[0])
    if "--addon" in argv:
        R.ADDON_DIR = os.path.abspath(argv[argv.index("--addon") + 1])
    os.makedirs(os.path.join(out, "scenes"), exist_ok=True)
    res = R.Results()
    sim = R.Sim(3, "main")
    R.scenario_boot(sim, res, verify=False)
    gm = sim.clients[0]

    def shot(name):
        gm.MOCK.CheckLayout()
        sim.advance(0.3)
        scene_path = os.path.join(out, "scenes", name + ".json")
        R.queue_render(res, gm, R.export_scene(gm, scene_path), scene_path, os.path.join(out, name + ".png"))

    def show(key, arg=None):
        gm.MOCK.HideSpecials(R.MAIN_FRAME)
        gm.call("ShowPage", gm.UI.ShowPage, gm.UI, key, arg)
        sim.advance(0.8)

    gm.call("OpenMain", gm.UI.OpenMain, gm.UI)
    sim.advance(1.0)
    for key in PAGES:
        show(key)
        shot(key + "-empty")
    R.raid_sequence(sim, res, "raid")
    gm.call("OpenMain", gm.UI.OpenMain, gm.UI)
    sim.advance(30)   # let any toasts run out
    for key in PAGES:
        show(key)
        shot(key)
    show("profile", "Bazza")
    shot("profile")
    R.run_renders(res, out)
    print("rendered", len(res.renders), "into", out)


if __name__ == "__main__":
    main(sys.argv[1:])
