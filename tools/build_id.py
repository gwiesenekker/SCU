"""Write the Git commit literal used by the SCU build resourcestring."""
import argparse
from pathlib import Path
import re
import subprocess
from tempfile import NamedTemporaryFile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_COMMIT = '$Format:%h$'


def commit_id():
    if (ROOT / '.git').exists():
        try:
            result = subprocess.run(['git', 'rev-parse', '--short', '--verify', 'HEAD'], cwd=ROOT,
                                    text=True, capture_output=True, check=True)
            return result.stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            pass
    return ARCHIVE_COMMIT if re.fullmatch(r'[0-9a-f]{4,64}', ARCHIVE_COMMIT) else 'unknown'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    path = parser.parse_args().output
    content = ("'" + commit_id() + "'\n").encode('ascii')
    if path.is_file() and path.read_bytes() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temp = Path(stream.name)
        stream.write(content)
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
