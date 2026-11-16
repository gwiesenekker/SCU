"""Drive the native Lazarus check against an isolated, audited CLI library."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
scu = root / "build/scu"
with tempfile.TemporaryDirectory(prefix="scu-gui-test-") as temporary:
    work = Path(temporary)
    library = work / "project.sqlite"
    def command(*args):
        result = subprocess.run([scu, library, *args], cwd=work, capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout
    command("initialize_library")
    source = work / "Main.pas"
    source.write_text("program main;\n// FIRST\nend.\n")
    command("import_deck", "deck_name=main.pas", "source_file=Main.pas")
    source.write_text("program main;\n// SECOND\nend.\n")
    command("import_deck", "deck_name=main.pas", "source_file=Main.pas")
    (work / "other.cpp").write_bytes(b"int other = 1;\r\n// no final newline")
    command("import_deck", "deck_name=other.cpp", "source_file=other.cpp")
    command("configure_library", "build_command=printf 'GUI-BUILD-START\\n'; sleep 0.2; printf 'GUI-BUILD-DONE\\n'")
    result = subprocess.run([root / "build/gui-check", library, root / "build/gui-check.png"], cwd=work,
                            capture_output=True, text=True, timeout=60,
                            env=dict(os.environ, XDG_CONFIG_HOME=str(work / "config")))
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    print(result.stdout.strip())
    preferences = json.loads((work / "config/scu/gui.json").read_text())
    assert preferences["editor_font_size"] == 13
    command("verify_audit")
    with closing(sqlite3.connect(library)) as database:
        events = [json.loads(line[65:]) for line, in database.execute("SELECT line FROM audit_records ORDER BY sequence")]
    commands = [event.get("command") for event in events if event.get("phase") == "begin"]
    for expected in ("import_deck", "extract_deck", "extract_version", "release_version", "display_deck_diff", "create_version", "configure_library"):
        assert expected in commands, (expected, commands)
    assert not any("scu$live_deck_version" in json.dumps(event.get("parameters", {}))
                   for event in events if event.get("phase") == "begin"), "Live selector leaked to CLI"
    extract = next(event for event in events if event.get("phase") == "begin"
                   and event.get("command") == "extract_deck")
    assert extract["parameters"]["deck_name"] == "main.pas"
    assert extract["parameters"]["output_file"] == "scu$deck_name"
    assert extract["parameters"]["build"] == "yes"
    assert extract["provided_arguments"] == ["deck_name"]
    print("GUI command audit and build integration passed")
