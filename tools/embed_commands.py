"""Compile commands.json as an RCDATA resource; --check detects stale output."""
import argparse
import json
from pathlib import Path
from stat import S_IMODE
import subprocess
import sys
from tempfile import NamedTemporaryFile, TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]


def generate(source, script, output, compiler='fpcres', check=False):
    data = source.read_bytes()
    if len(data) > 1024 * 1024:
        raise ValueError('commands.json exceeds the 1 MiB catalog limit')
    document = json.loads(data.decode('utf-8'))
    if not isinstance(document, dict) or document.get('format') != 4:
        raise ValueError('Expected commands.json format 4')
    with TemporaryDirectory(prefix='scu-resource-') as directory:
        compiled = Path(directory) / 'commands.res'
        subprocess.run([compiler, '-of', 'res', str(script.resolve()), '-o', str(compiled)],
                       check=True, capture_output=True)
        expected = compiled.read_bytes()
    if output.is_file() and output.read_bytes() == expected:
        return
    if check:
        raise ValueError('Embedded resource is stale; run python3 tools/embed_commands.py')
    mode = S_IMODE(output.stat().st_mode) if output.exists() else 0o644
    with NamedTemporaryFile(dir=output.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(expected)
            stream.close()
            temporary.chmod(mode)
            temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'commands.json')
    parser.add_argument('--script', type=Path, default=ROOT / 'src/scucommands.rc')
    parser.add_argument('--output', type=Path, default=ROOT / 'src/scucommands.res')
    parser.add_argument('--fpcres', default='fpcres', help='FPC resource compiler executable')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        generate(args.source, args.script, args.output, args.fpcres, args.check)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or b'') + (error.stdout or b'')
        print('Embedded catalog: resource compiler failed: ' + detail.decode('utf-8', errors='replace').strip(), file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f'Embedded catalog: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
