#!/usr/bin/env python3
"""Runtime DLL regressions. Native Linux/Windows or a Windows probe with --wine.

SCU_TEST_DLL_DIRECTORY supplies real Windows DLL fixtures (default probe folder).
SCU_TEST_WINDOWS_FPC optionally supplies the Windows FPC compiler command for
building deliberately incomplete DLLs; --wine requires a cross compiler.
"""
import base64
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/dll_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'
FIXTURES = Path(os.environ.get('SCU_TEST_DLL_DIRECTORY', PROBE.parent))
_probe_bytes = PROBE.read_bytes()
_pe_offset = int.from_bytes(_probe_bytes[0x3c:0x40], 'little') if WINDOWS else 0
CRYPTO_NAME = 'libcrypto-3-x64.dll' if WINDOWS and _probe_bytes[_pe_offset+4:_pe_offset+6] == b'\x64\x86' else 'libcrypto-3.dll'


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


class DLLTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mocktemp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.mocktemp.cleanup)
        cls.mockroot = Path(cls.mocktemp.name)
        cls.mocks = {}
        if WINDOWS:
            cls.real = {}
            for component, names in [('sqlite', ['sqlite3.dll']), ('zstd', ['libzstd.dll', 'zstd.dll']),
                                     ('crypto', [CRYPTO_NAME, 'libcrypto-3.dll'])]:
                cls.real[component] = next((FIXTURES / n for n in names if (FIXTURES / n).exists()), None)
                if cls.real[component] is None:
                    raise RuntimeError('Missing real ' + component + ' fixture in ' + str(FIXTURES))
            compiler = shlex.split(os.environ.get('SCU_TEST_WINDOWS_FPC', 'fpc'))
            for kind in ['sqlite-old', 'sqlite-missing', 'sqlite-nothreads', 'zstd-old',
                         'zstd-missing', 'crypto-old', 'crypto-missing', 'dependency', 'dependent-zstd']:
                directory = cls.mockroot / kind
                directory.mkdir()
                code = ['library stub;', '{$mode objfpc}{$H+}', 'uses ctypes;']
                exports = []
                def function(name, result, value, parameters=''):
                    code.append(f'function {name}({parameters}): {result}; cdecl; begin Result := {value}; end;')
                    exports.append(name)
                if kind.startswith('sqlite'):
                    function('sqlite3_libversion_number', 'cint', '3000000' if kind.endswith('old') else '3040000')
                    function('sqlite3_threadsafe', 'cint', '0' if kind.endswith('nothreads') else '1')
                elif kind.startswith('zstd'):
                    function('ZSTD_versionNumber', 'cuint', '10200' if kind.endswith('old') else '10500')
                elif kind.startswith('crypto'):
                    function('OpenSSL_version_num', 'culong', '$10101000' if kind.endswith('old') else '$30000000')
                elif kind == 'dependency':
                    function('Marker', 'cuint', '10500')
                else:
                    code.append("function Marker: cuint; cdecl; external 'scu_missing_dependency.dll';")
                    function('ZSTD_versionNumber', 'cuint', 'Marker()')
                code.append('exports ' + ', '.join(exports) + '; begin end.')
                source = directory / 'stub.pas'
                source.write_text('\n'.join(code))
                result = subprocess.run(compiler + ['-FU' + str(directory), '-FE' + str(directory), str(source)],
                                        capture_output=True, timeout=60)
                if result.returncode:
                    raise RuntimeError(result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace'))
                path = directory / 'stub.dll'
                if not path.exists() or path.read_bytes()[:2] != b'MZ':
                    raise RuntimeError('SCU_TEST_WINDOWS_FPC must build Windows DLLs')
                cls.mocks[kind] = path

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.cwd = self.root / 'cwd'
        self.app.mkdir(); self.cwd.mkdir()
        self.executable = self.app / PROBE.name
        shutil.copy2(PROBE, self.executable)
        if WINDOWS:
            for dependency in FIXTURES.glob('vcruntime*.dll'):
                shutil.copy2(dependency, self.app / dependency.name)
        self.source = self.root / 'source'
        self.source.write_bytes(bytes(range(256)) * 100 + b'\x00\r\nlast\xff')
        self.database = self.root / 'library.sqlite'

    def install(self, component, name=None, source=None, directory=None):
        source = source or self.real[component]
        path = (directory or self.app) / (name or source.name)
        shutil.copy2(source, path)
        return path

    def install_all(self):
        if WINDOWS:
            for component in self.real:
                self.install(component)

    def probe(self, *args, error=None, env=None):
        executable = str(self.executable)
        if os.name == 'nt' and len(executable) >= 248 and not executable.startswith('\\\\?\\'):
            executable = '\\\\?\\' + executable
        command = (['wine', executable] if WINE else [executable])
        result = subprocess.run(command + [argument(v) for v in args], cwd=self.cwd,
                                capture_output=True, env=env, timeout=45)
        if error is None:
            self.assertEqual(result.returncode, 0, (result.stderr + result.stdout).decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result.stdout.replace(b'\r\n', b'\n')

    def test_checksum_vectors_and_binary_zstd_round_trip(self):
        self.install_all()
        data = self.source.read_bytes()
        expected = (hashlib.sha1(data).hexdigest() + '\n' + hashlib.sha256(data).hexdigest() + '\n').encode()
        self.assertEqual(self.probe('roundtrip', self.source), expected)
        self.source.write_bytes(b'')
        self.assertEqual(self.probe('roundtrip', self.source),
                         (hashlib.sha1(b'').hexdigest() + '\n' + hashlib.sha256(b'').hexdigest() + '\n').encode())

    def test_concurrent_first_use_of_all_three_libraries(self):
        self.install_all()
        self.assertEqual(self.probe('threads', self.root), b'threads ok\n')
        for index in range(8):
            with sqlite3.connect(self.root / f'{index}.sqlite') as db:
                self.assertEqual(db.execute('SELECT value FROM test').fetchall(), [('payload',)])

    def test_sqlite_persistence_through_loaded_api(self):
        if WINDOWS:
            self.install('sqlite')
        self.assertEqual(self.probe('sqlite', self.database), b'sqlite ok\n')
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute('SELECT value FROM test').fetchall(), [('payload',)])

    def test_decode_validation_is_unchanged(self):
        self.install_all()
        digest = hashlib.sha1(b'abc').hexdigest()
        self.probe('decode', '!!!!', digest, 3, error=b'Invalid deck base64')
        self.source.write_bytes(b'abc')
        encoded = self.probe('encode', self.source).strip().decode()
        self.probe('decode', encoded, digest, 4, error=b'Deck size does not match')
        self.probe('decode', encoded, '0' * 40, 3, error=b'Deck SHA-1 or size verification failed')
        concatenated = base64.b64encode(base64.b64decode(encoded) * 2).decode()
        self.probe('decode', concatenated, digest, 3, error=b'Expected one zstd frame')

    @unittest.skipUnless(WINDOWS, 'Windows lazy loading')
    def test_startup_needs_no_optional_dlls(self):
        self.assertEqual(self.probe('noop'), b'ready\n')
        (self.app / 'sqlite3.dll').write_bytes(b'not a DLL')
        self.assertEqual(self.probe('noop'), b'ready\n')

    @unittest.skipUnless(WINDOWS, 'Windows primary search policy')
    def test_missing_dlls_report_component_and_directory_without_creating_database(self):
        for mode, extra, component in [('sqlite', [self.database], b'SQLite'), ('zstd', [], b'zstd'), ('crypto', [], b'OpenSSL')]:
            self.probe(mode, *extra, error=b'Could not find ' + component)
        self.assertFalse(self.database.exists())

    @unittest.skipUnless(WINDOWS, 'Windows isolated search')
    def test_current_directory_and_path_cannot_supply_primary_dlls(self):
        environment = dict(os.environ)
        pathdir = argument(self.cwd)
        environment['PATH'] = pathdir + (';' if os.name == 'nt' else ':') + environment.get('PATH', '')
        for component, dll in self.real.items():
            self.install(component, directory=self.cwd)
            extra = [self.database] if component == 'sqlite' else []
            self.probe(component, *extra, env=environment, error=b'Could not find')

    @unittest.skipUnless(WINDOWS, 'Windows app-local policy')
    def test_valid_app_local_dlls_win_over_invalid_cwd_dlls(self):
        self.install_all()
        for name in ['sqlite3.dll', 'libzstd.dll', 'zstd.dll', 'libcrypto-3.dll', 'libcrypto-3-x64.dll']:
            (self.cwd / name).write_bytes(b'bad image')
        self.assertEqual(self.probe('threads', self.root), b'threads ok\n')

    @unittest.skipUnless(WINDOWS, 'Windows DLL aliases')
    def test_zstd_alternate_filename(self):
        self.install('zstd', name='zstd.dll')
        self.assertEqual(self.probe('zstd'), b'zstd ok\n')

    @unittest.skipUnless(WINDOWS, 'Windows DLL alias failure handling')
    def test_broken_preferred_name_does_not_fall_through_to_working_alias(self):
        self.install('zstd', name='zstd.dll')
        (self.app / 'libzstd.dll').write_bytes(b'bad image')
        self.probe('zstd', error=b'Could not load zstd DLL')

    @unittest.skipUnless(WINDOWS, 'Windows diagnostic export checks')
    def test_missing_exports_are_named_for_all_three_libraries(self):
        for component, name, missing in [('sqlite', 'sqlite3.dll', b'sqlite3_open_v2'),
                                         ('zstd', 'libzstd.dll', b'ZSTD_compressBound'),
                                         ('crypto', CRYPTO_NAME, b'OPENSSL_init_crypto')]:
            path = self.install(component, name=name, source=self.mocks[component + '-missing'])
            self.probe(component, *([self.database] if component == 'sqlite' else []), error=missing)
            path.unlink()
        self.assertFalse(self.database.exists())

    @unittest.skipUnless(WINDOWS, 'Windows compatibility checks')
    def test_incompatible_versions_and_thread_unsafe_sqlite_are_rejected(self):
        for component, name, kind, error in [
                ('sqlite', 'sqlite3.dll', 'sqlite-old', b'SQLite 3.38'),
                ('sqlite', 'sqlite3.dll', 'sqlite-nothreads', b'without thread safety'),
                ('zstd', 'libzstd.dll', 'zstd-old', b'zstd 1.3'),
                ('crypto', CRYPTO_NAME, 'crypto-old', b'major version 3')]:
            path = self.install(component, name=name, source=self.mocks[kind])
            self.probe(component, *([self.database] if component == 'sqlite' else []), error=error)
            path.unlink()

    @unittest.skipUnless(WINDOWS, 'Windows image format validation')
    def test_wrong_architecture_reports_image_error(self):
        data = bytearray(self.mocks['zstd-missing'].read_bytes())
        pe = int.from_bytes(data[0x3c:0x40], 'little')
        machine = bytes(data[pe + 4:pe + 6])
        data[pe + 4:pe + 6] = b'\x4c\x01' if machine != b'\x4c\x01' else b'\x64\x86'
        (self.app / 'libzstd.dll').write_bytes(data)
        self.probe('zstd', error=b'check its architecture')

    @unittest.skipUnless(WINDOWS, 'Windows dependency search policy')
    def test_cwd_cannot_supply_missing_transitive_dependency(self):
        self.install('zstd', name='libzstd.dll', source=self.mocks['dependent-zstd'])
        self.install('zstd', name='scu_missing_dependency.dll', source=self.mocks['dependency'], directory=self.cwd)
        self.probe('zstd', error=b'app-local dependencies')
        self.install('zstd', name='scu_missing_dependency.dll', source=self.mocks['dependency'])
        self.probe('zstd', error=b'ZSTD_compressBound') # primary can load after dependency installation

    @unittest.skipUnless(WINDOWS, 'Windows failure state rollback')
    def test_failed_binding_can_be_retried_after_replacing_dll_in_same_process(self):
        for component, name in [('sqlite', 'sqlite3.dll'), ('zstd', 'libzstd.dll'), ('crypto', CRYPTO_NAME)]:
            path = self.install(component, name=name, source=self.mocks[component + '-missing'])
            output = self.probe('retry', component, name, self.real[component], self.database)
            self.assertIn(b'first failure:', output)
            self.assertIn(b'retry ok', output)
            path.unlink()

    def prepare_app_directory(self, directory):
        directory.mkdir(parents=True)
        self.app = directory
        self.executable = self.app / PROBE.name
        shutil.copy2(PROBE, self.executable)
        for dependency in FIXTURES.glob('vcruntime*.dll'):
            shutil.copy2(dependency, self.app / dependency.name)
        self.install_all()

    @unittest.skipUnless(WINDOWS, 'Windows Unicode DLL paths')
    def test_unicode_executable_directory(self):
        self.prepare_app_directory(self.root / '日本 app')
        self.assertEqual(self.probe('crypto'), b'crypto ok\n')
        self.assertEqual(self.probe('sqlite', self.database), b'sqlite ok\n')
        self.assertEqual(self.probe('zstd'), b'zstd ok\n')

    @unittest.skipUnless(WINDOWS, 'Windows long DLL paths')
    def test_long_executable_directory(self):
        self.prepare_app_directory(self.root / ('a' * 110) / ('b' * 110) / '日本 app')
        if WINE:
            # Establish failure before any optional DLL is touched. Wine's
            # ShellExecute launcher cannot start this long executable path.
            result = subprocess.run(['wine', str(self.executable), 'noop'], cwd=self.cwd,
                                    capture_output=True, timeout=30)
            if result.returncode and b'ShellExecuteEx failed' in result.stdout:
                self.skipTest('Wine cannot start a long executable path, even with no optional DLL use')
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.probe('crypto'), b'crypto ok\n')
        self.assertEqual(self.probe('sqlite', self.database), b'sqlite ok\n')
        self.assertEqual(self.probe('zstd'), b'zstd ok\n')

    @unittest.skipUnless(WINDOWS, 'Windows library isolation')
    def test_each_component_is_loaded_only_when_needed(self):
        self.install('crypto')
        (self.app / 'sqlite3.dll').write_bytes(b'bad image')
        (self.app / 'libzstd.dll').write_bytes(b'bad image')
        self.assertEqual(self.probe('crypto'), b'crypto ok\n')

    @unittest.skipUnless(WINDOWS, 'Windows OpenSSL built-in checksums')
    def test_openssl_external_configuration_is_not_required(self):
        self.install('crypto')
        configuration = self.cwd / 'openssl.cnf'
        configuration.write_text('openssl_conf = init\n[init]\nproviders = providers\n[providers]\nnull = null_section\n[null_section]\nactivate = 1\n')
        environment = dict(os.environ, OPENSSL_CONF=argument(configuration), OPENSSL_MODULES=argument(self.cwd))
        self.assertEqual(self.probe('crypto', env=environment), b'crypto ok\n')

if __name__ == '__main__':
    unittest.main()
