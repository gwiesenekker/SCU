"""Embedded-catalog generation checks; CLI behavior is covered by portable_cli."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / 'tools/embed_commands.py'

class EmbeddedCommandsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'commands.json'
        self.output = self.root / 'commands.res'
        self.script = self.root / 'commands.rc'
        self.script.write_text('SCU_COMMANDS RCDATA "commands.json"\n')

    def run_generator(self, *args, error=None):
        result = subprocess.run([sys.executable, str(GENERATOR), '--source', str(self.source),
                                 '--output', str(self.output), '--script', str(self.script), *args], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0 if error is None else 1, result.stderr)
        if error is not None:
            self.assertIn(error, result.stderr)

    def test_generated_bytes_preserve_utf8_quotes_backslashes_and_line_endings(self):
        data = (json.dumps({'format': 4, 'commands': [], 'text': "日本 'quoted' \\path\n"},
                           ensure_ascii=False, indent=2) + '\n').replace('\n', '\r\n').encode()
        self.source.write_bytes(data)
        self.run_generator()
        resource = self.output.read_bytes()
        # Win32 .res containers start with a null record followed by RCDATA.
        offset = 0
        payloads = []
        while offset + 8 <= len(resource):
            size, header = struct.unpack_from('<II', resource, offset)
            self.assertGreaterEqual(header, 8)
            if size:
                self.assertEqual(struct.unpack_from('<HH', resource, offset + 8), (0xffff, 10))
                self.assertIn('SCU_COMMANDS'.encode('utf-16-le'), resource[offset:offset + header])
                payloads.append(resource[offset + header:offset + header + size])
            offset = (offset + header + size + 3) & ~3
        self.assertEqual(payloads, [data])
        before = self.output.stat().st_mtime_ns
        self.run_generator()
        self.run_generator('--check')
        self.assertEqual(self.output.stat().st_mtime_ns, before)

    def test_check_detects_changed_source_without_rewriting_resource(self):
        self.source.write_text('{"format":4,"commands":[]}')
        self.run_generator()
        original = self.output.read_bytes()
        self.source.write_text('{"format":4,"commands":[],"changed":true}')
        self.run_generator('--check', error=b'stale')
        self.assertEqual(self.output.read_bytes(), original)
        self.run_generator()
        self.run_generator('--check')
        self.assertNotEqual(self.output.read_bytes(), original)

    def test_invalid_or_oversized_source_preserves_existing_resource(self):
        self.output.write_bytes(b'keep previous resource')
        for data in [b'{', b'[]', b'{"format":3}', b' ' * (1024 * 1024 + 1)]:
            self.source.write_bytes(data)
            self.run_generator(error=b'Embedded catalog:')
            self.assertEqual(self.output.read_bytes(), b'keep previous resource')

    def test_resource_compiler_failure_preserves_previous_resource(self):
        self.source.write_text('{"format":4,"commands":[]}')
        self.run_generator()
        original = self.output.read_bytes()
        self.script.write_text('SCU_COMMANDS RCDATA "missing.json"\n')
        self.run_generator(error=b'resource compiler failed')
        self.assertEqual(self.output.read_bytes(), original)

    def test_resource_stream_roundtrip_and_relink_after_catalog_edit(self):
        # Exercise the real Pascal resource loader, including recompilation
        # while the unit source itself remains unchanged.
        shutil.copy2(ROOT / 'src/scuembeddedcommands.pas', self.root / 'scuembeddedcommands.pas')
        self.output = self.root / 'scucommands.res'
        program = self.root / 'resource_probe.pas'
        program.write_text('program ResourceProbe;\n{$mode objfpc}{$H+}\n'
                           'uses SysUtils, ScuEmbeddedCommands;\n'
                           'var Data: RawByteString;\n'
                           'begin Data := EmbeddedCommandsJSON;\n'
                           'if Length(Data)>0 then if FileWrite(StdOutputHandle, Data[1], Length(Data)) <> Length(Data) then Halt(1); end.\n')
        executable = self.root / ('resource_probe.exe' if os.name == 'nt' else 'resource_probe')
        for word in ['first', 'other']:
            data = json.dumps({'format': 4, 'text': word + ' 日本 "quote" \\path'}, ensure_ascii=False).encode()
            self.source.write_bytes(data)
            self.run_generator()
            compile_result = subprocess.run(['fpc', '-Fu' + str(self.root), '-FU' + str(self.root),
                                             '-FE' + str(self.root), str(program)],
                                            capture_output=True, timeout=30)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            loaded = subprocess.run([str(executable)], capture_output=True, timeout=15)
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            self.assertEqual(loaded.stdout, data)

    def test_checked_in_resource_matches_current_catalog(self):
        result = subprocess.run([sys.executable, str(GENERATOR), '--check'], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == '__main__':
    unittest.main()
