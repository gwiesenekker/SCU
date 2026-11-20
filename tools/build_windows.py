#!/usr/bin/env python3
"""Build the Win64 CLI with an installed Free Pascal toolchain; optionally test it.

No compiler or DLLs are downloaded. Native Windows uses the same source and
command catalog as Linux. Cross-compilers can supply their unit/search flags
with repeated --fpc-option arguments.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DLL_NAMES = ('sqlite3.dll', 'libzstd.dll', 'libcrypto-3.dll')
DLL_GROUPS = (('sqlite3.dll',), ('libzstd.dll', 'zstd.dll'),
              ('libcrypto-3-x64.dll', 'libcrypto-3.dll'))


def build_gui(args, output):
    subprocess.run([getattr(args, 'fpcres', 'fpcres'), '-of', 'res', 'gui/scumanual.rc',
                    '-o', 'gui/scumanual.res'], cwd=ROOT, check=True)
    # Generate local projects rather than rewriting tracked LPI files or sharing
    # Linux LCL objects. Paths are absolute so Unicode/spaced output roots work.
    projects = [('gui/scu_gui.lpi', 'scu-gui.exe', 'gui-units')]
    if args.gui_test:
        projects.append(('tests/gui_check.lpi', 'gui-check.exe', 'gui-test-units'))
    for template, executable, units in projects:
        tree = ET.parse(ROOT / template)
        project = tree.getroot()
        options = project.find('CompilerOptions')
        options.find('Target/Filename').set('Value', str(output / executable))
        search = options.find('SearchPaths')
        search.find('UnitOutputDirectory').set('Value', str(output / units))
        search.find('OtherUnitFiles').set('Value', str(ROOT / 'src') + ';' + str(ROOT / 'gui'))
        unit = project.find('ProjectOptions/Units/Unit0/Filename')
        unit.set('Value', str((ROOT / template).parent / unit.get('Value')))
        filename = output / Path(template).name
        tree.write(filename, encoding='utf-8', xml_declaration=True)
        command = [args.lazbuild, '--build-all', '--os=win64', '--cpu=x86_64', '--widgetset=win32',
                   '--compiler=' + args.fpc]
        command += ['--opt=' + subprocess.list2cmdline([option]) for option in args.fpc_option]
        command.append(str(filename))
        subprocess.run(command, cwd=ROOT, check=True)
        if not (output / executable).is_file():
            raise ValueError(f'Lazarus did not produce {output / executable}')


def build(args):
    output = args.output.resolve()
    gui_test = getattr(args, 'gui_test', False)
    if gui_test and not getattr(args, 'gui', False):
        raise ValueError('--gui-test requires --gui')
    if args.wine and not (args.test or gui_test):
        raise ValueError('--wine requires --test or --gui-test')
    if args.wine and sys.platform == 'win32':
        raise ValueError('--wine is for cross-testing on Linux; omit it on Windows')
    # Resolve every input before copying or compiling, so missing runtime files
    # do not leave a deceptively incomplete new bundle.
    runtime = []
    if args.dll_directory:
        directory = args.dll_directory.resolve()
        for group in DLL_GROUPS:
            candidate = next((directory / name for name in group if (directory / name).is_file()), None)
            if candidate is None:
                raise ValueError(f'Runtime DLL does not exist: {directory} (expected {" or ".join(group)})')
            runtime.append(candidate)
    runtime.extend(path.resolve() for path in args.runtime_dll)
    names = set()
    for path in runtime:
        if not path.is_file():
            raise ValueError(f'Runtime DLL does not exist: {path}')
        if path.suffix.lower() != '.dll':
            raise ValueError(f'Expected a runtime DLL: {path}')
        if path.name.casefold() in names:
            raise ValueError(f'Duplicate runtime DLL name: {path.name}')
        names.add(path.name.casefold())
    if args.test or gui_test:
        for group in DLL_GROUPS:
            if not any(name in names or (output / name).is_file() for name in group):
                raise ValueError(f'Testing needs {" or ".join(group)} beside scu.exe; supply --dll-directory')
    if args.dll_directory:
        for group in DLL_GROUPS:
            for name in group:
                if (output / name).is_file() and name not in names:
                    raise ValueError(f'Conflicting previously staged DLL: {output / name}. Use a clean output directory.')
    units = output / 'units'
    units.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / 'tools/embed_commands.py'), '--fpcres', getattr(args, 'fpcres', 'fpcres')], cwd=ROOT, check=True)
    command = [args.fpc, *args.fpc_option, '-Twin64', '-O2', '-B',
               '-Fu' + str(ROOT / 'src'), '-FU' + str(units), '-FE' + str(output),
               '-o' + str(output / 'scu.exe'), str(ROOT / 'src' / 'scu.pas')]
    subprocess.run(command, cwd=ROOT, check=True)
    executable = output / 'scu.exe'
    if not executable.is_file():
        raise ValueError(f'The compiler did not produce {executable}')
    shutil.copyfile(ROOT / 'commands.json', output / 'commands.json')
    for path in runtime:
        destination = output / path.name
        if path != destination:
            shutil.copyfile(path, destination)
    print(f'Windows CLI: {executable}', flush=True)
    if getattr(args, 'gui', False):
        build_gui(args, output)
    if args.test:
        command = [sys.executable, str(ROOT / 'tests' / 'portable_cli.py'), str(executable)]
        if args.wine:
            command.append('--wine')
        subprocess.run(command, cwd=ROOT, check=True)
    if gui_test:
        command = [sys.executable, str(ROOT / 'tests' / 'gui_integration.py'),
                   '--scu', str(executable), '--gui-check', str(output / 'gui-check.exe')]
        if args.wine:
            command.append('--wine')
        subprocess.run(command, cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fpc', default='fpc', help='Free Pascal compiler executable (default: fpc)')
    parser.add_argument('--fpcres', default='fpcres', help='FPC resource compiler executable (default: fpcres)')
    parser.add_argument('--fpc-option', action='append', default=[],
                        help='Additional compiler argument; repeat, using --fpc-option=-FuPATH for flags')
    parser.add_argument('--output', type=Path, default=ROOT / 'build' / 'windows',
                        help='Output directory (default: build/windows)')
    parser.add_argument('--dll-directory', type=Path,
                        help='Directory containing the three required Win64 runtime DLLs')
    parser.add_argument('--runtime-dll', action='append', type=Path, default=[],
                        help='Additional app-local dependency DLL to copy; repeat as needed')
    parser.add_argument('--gui', action='store_true', help='Also build the native Win32-widget GUI (requires Lazarus/SynEdit)')
    parser.add_argument('--gui-test', action='store_true', help='Build and run GUI integration checks; requires --gui')
    parser.add_argument('--lazbuild', default='lazbuild', help='Lazarus build executable (default: lazbuild)')
    parser.add_argument('--test', action='store_true', help='Run the portable CLI suite after building')
    parser.add_argument('--wine', action='store_true', help='Run tests through Wine on Linux')
    args = parser.parse_args()
    # Compiler output is inherited unchanged. Our own reports must also survive
    # redirected Windows output when paths are outside the legacy code page.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(errors='backslashreplace')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(errors='backslashreplace')
    try:
        build(args)
    except subprocess.CalledProcessError as error:
        print(f'Windows build/test failed (exit {error.returncode}).', file=sys.stderr)
        return error.returncode if 0 < error.returncode < 256 else 1
    except (OSError, ValueError) as error:
        print(f'Windows build: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
