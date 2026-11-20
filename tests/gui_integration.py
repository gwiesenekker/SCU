"""Drive the native Lazarus check against an isolated, audited CLI library."""
from contextlib import closing
import json
import argparse
import os
from pathlib import Path
import sqlite3
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scu', type=Path, default=root / ('build/windows/scu.exe' if os.name == 'nt' else 'build/scu'))
parser.add_argument('--gui-check', type=Path, default=root / ('build/windows/gui-check.exe' if os.name == 'nt' else 'build/gui-check'))
parser.add_argument('--wine', action='store_true')
parser.add_argument('--embedded-catalog', action='store_true', help='Test a standalone bundle without commands.json')
args = parser.parse_args()
scu = args.scu.resolve()
gui_check = args.gui_check.resolve()
screenshot = gui_check.with_suffix('.png')
windows = args.wine or os.name == 'nt'
def argument(value):
    if args.wine and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)
def run(executable, *values, **options):
    command = (['wine', str(executable)] if args.wine else [str(executable)])
    return subprocess.run(command + [argument(v) for v in values], encoding='utf-8', **options)
with tempfile.TemporaryDirectory(prefix="scu-gui-test-") as temporary:
    work = Path(temporary)
    if windows:
        work = work / 'work 日本'
        work.mkdir()
    if args.embedded_catalog:
        bundle = work / 'standalone'
        bundle.mkdir()
        assert not (bundle / "MANUAL.md").exists()
        for executable in [scu, gui_check]:
            shutil.copy2(executable, bundle / executable.name)
        if windows:
            for dll in scu.parent.glob('*.dll'):
                shutil.copy2(dll, bundle / dll.name)
        scu, gui_check = bundle / scu.name, bundle / gui_check.name
    library = work / ('project 日本.sqlite' if windows else 'project.sqlite')
    def command(*args):
        result = run(scu, library, *args, cwd=work, capture_output=True, text=True, timeout=20)
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
    build = 'echo GUI-BUILD-START & echo GUI-BUILD-DONE' if windows else "printf 'GUI-BUILD-START\\n'; sleep 0.2; printf 'GUI-BUILD-DONE\\n'"
    command('configure_library', 'build_command=' + build)
    config_path = work / ('config 日本' if windows else 'config')
    configuration = dict(os.environ)
    if windows:
        configuration.update(LOCALAPPDATA=argument(config_path), APPDATA=argument(config_path),
                             SCU_GUI_TEST_CONFIG=argument(config_path))
    else:
        configuration['XDG_CONFIG_HOME'] = str(work / 'config')
    result = run(gui_check, library, screenshot, cwd=work,
                 capture_output=True, text=True, timeout=120 if windows else 60, env=configuration)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    print(result.stdout.strip())
    preferences = json.loads((config_path / "scu/gui.json").read_text(encoding="utf-8"))
    assert preferences["editor_font_size"] == 13
    command("verify_audit_trail")
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
    if args.embedded_catalog:
        assert not (gui_check.parent / 'commands.json').exists()
    print("GUI command audit and build integration passed" + (" (embedded catalog)" if args.embedded_catalog else ""))
