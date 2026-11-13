"""Sort the SCU command catalog while retaining its compact alias lists."""

from decimal import Decimal
import json
from pathlib import Path
from stat import S_IMODE
import sys
from tempfile import NamedTemporaryFile


def format_json(value, depth=0):
    indent = "  " * depth
    child_indent = indent + "  "
    if isinstance(value, dict) and value:
        entries = [
            f"{json.dumps(key, ensure_ascii=False)}: {format_json(item, depth + 1)}"
            for key, item in value.items()
        ]
        return "{\n" + child_indent + (",\n" + child_indent).join(entries) + "\n" + indent + "}"
    if isinstance(value, list):
        entries = [format_json(item, depth + 1) for item in value]
        if any("\n" in entry for entry in entries):
            return "[\n" + child_indent + (",\n" + child_indent).join(entries) + "\n" + indent + "]"
        return "[" + ", ".join(entries) + "]"
    if isinstance(value, Decimal):
        return str(value)
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def format_commands(path):
    path = path.resolve()
    original = path.read_bytes()
    catalog = json.loads(original, parse_float=Decimal)
    for option in ("library_argument", "batch_argument"):
        catalog.get(option, {}).get("aliases", []).sort()
    if "argument_aliases" in catalog:
        catalog["argument_aliases"] = dict(sorted(catalog["argument_aliases"].items()))
    catalog["commands"].sort(key=lambda command: command["name"])
    for command in catalog["commands"]:
        command.get("aliases", []).sort()
        for parameter in command.get("arguments", []):
            if isinstance(parameter, dict):
                parameter.get("aliases", []).sort()
                for value in parameter.get("values", []):
                    if isinstance(value, dict):
                        value.get("aliases", []).sort()

    formatted = (format_json(catalog) + "\n").encode("utf-8")
    if formatted == original:
        return

    with NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        replacement = Path(temporary.name)
        try:
            temporary.write(formatted)
            temporary.close()
            replacement.chmod(S_IMODE(path.stat().st_mode))
            replacement.replace(path)
        finally:
            replacement.unlink(missing_ok=True)


if __name__ == "__main__":
    format_commands(Path(sys.argv[1]))
