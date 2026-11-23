"""Write the Git commit literal used by the SCU build resourcestring."""
import argparse
import os
from pathlib import Path
import re
import subprocess
from tempfile import NamedTemporaryFile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_COMMIT = '$Format:%h$'


def shared_checkout_id():
    """Read HEAD from a shared ordinary checkout when Git cannot run on this host."""
    git_dir = ROOT / '.git'
    if not git_dir.is_dir():
        return ''
    try:
        head = (git_dir / 'HEAD').read_text(encoding='utf-8').strip()
        if head.startswith('ref: '):
            ref = head[5:]
            if not ref.startswith('refs/') or any(part in ('', '.', '..') for part in ref.split('/')) or any(c in ref for c in '\\:'):
                return ''
            try:
                head = (git_dir / ref).read_text(encoding='ascii').strip()
            except FileNotFoundError:
                with (git_dir / 'packed-refs').open(encoding='utf-8') as entries:
                    head = next((line.split(' ', 1)[0] for line in entries
                                 if line.rstrip('\n').endswith(' ' + ref)), '')
        if re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', head):
            return head[:7]
    except (OSError, UnicodeError):
        pass
    return ''


def commit_id():
    if (ROOT / '.git').exists():
        try:
            result = subprocess.run(['git', 'rev-parse', '--short', '--verify', 'HEAD'], cwd=ROOT,
                                    text=True, capture_output=True, check=True)
            return result.stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            pass
        shared = shared_checkout_id()
        if shared:
            return shared
    if re.fullmatch(r'[0-9a-f]{4,64}', ARCHIVE_COMMIT):
        return ARCHIVE_COMMIT
    supplied = os.environ.get('SCU_BUILD_COMMIT', '')
    if supplied and not re.fullmatch(r'[0-9a-fA-F]{4,64}', supplied):
        raise ValueError('SCU_BUILD_COMMIT must be a hexadecimal Git commit ID (4 to 64 digits).')
    return supplied.lower() or 'unknown'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    path = parser.parse_args().output
    try:
        revision = commit_id()
    except ValueError as error:
        parser.error(str(error))
    content = ("'" + revision + "'\n").encode('ascii')
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
