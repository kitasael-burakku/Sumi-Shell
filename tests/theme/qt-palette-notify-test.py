import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys

tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "sumi"
spec = importlib.util.spec_from_file_location("notify", tree / "scripts/qt-palette-notify.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
results = []

with tempfile.TemporaryDirectory(prefix="kt-qt-notify-") as tmp:
    root = Path(tmp)
    config = root / "qt6ct.conf"
    palette = root / "colors/palette.conf"
    palette.parent.mkdir()
    palette.write_text("[ColorScheme]\nactive_colors=#112233\n")

    def check(name, condition):
        results.append({"test": name, "ok": bool(condition)})

    check("missing profile is not created", module.notify(config, palette)["reason"] == "missing-file" and not config.exists())
    content = f"[Appearance]\ncustom_palette=true\ncolor_scheme_path={palette}\n# preserve me\n"
    config.write_text(content)
    before = config.stat().st_mtime_ns
    check("selected profile notified", module.notify(config, palette)["status"] == "notified")
    check("configuration bytes preserved", config.read_text() == content)
    check("notification changes mtime", config.stat().st_mtime_ns > before)
    config.write_text(content.replace("true", "false"))
    before = config.stat().st_mtime_ns
    check("disabled custom palette skipped", module.notify(config, palette)["reason"] == "custom-palette-disabled" and config.stat().st_mtime_ns == before)
    config.write_text(content.replace(str(palette), str(root / "other.conf")))
    check("unrelated selection skipped", module.notify(config, palette)["reason"] == "different-palette")
    config.write_text(content.replace(str(palette), "relative.conf"))
    check("relative selection not guessed", module.notify(config, palette)["reason"] == "different-palette")
    config.write_text(content.replace(str(palette), '"'+str(palette)+'"'))
    check("quoted absolute selection", module.notify(config, palette)["status"] == "notified")
    alias = root / "alias.conf"
    alias.symlink_to(palette)
    config.write_text(content.replace(str(palette), str(alias)))
    check("same palette through symlink", module.notify(config, palette)["status"] == "notified")
    check("missing palette skipped", module.notify(config, root / "missing.conf")["reason"] == "missing-file")
    config.write_text("[Fonts]\ngeneral=unchanged\n")
    check("no Appearance section skipped", module.notify(config, palette)["reason"] == "custom-palette-disabled")

print(json.dumps({"pass":sum(r['ok'] for r in results),"fail":sum(not r['ok'] for r in results),"results":results},indent=2))
raise SystemExit(any(not r['ok'] for r in results))
