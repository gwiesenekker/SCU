#!/usr/bin/env python3
"""Build-driver regressions, independent of an installed Windows compiler."""
import argparse
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('scu_windows_build', Path(__file__).resolve().parents[1] / 'tools/build_windows.py')
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class WindowsBuildTests(unittest.TestCase):
    def setUp(self):
        output = patch('sys.stdout', new=io.StringIO())
        output.start()
        self.addCleanup(output.stop)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / 'build space 日本'
        self.dlls = self.root / 'runtime'
        self.dlls.mkdir(parents=True)
        for name in builder.DLL_NAMES:
            (self.dlls / name).write_bytes(name.encode())
        self.args = argparse.Namespace(gui=False, gui_test=False, lazbuild='lazarus builder', output=self.root / 'output', dll_directory=self.dlls,
            runtime_dll=[], fpc='compiler with spaces', fpc_option=['-Xi', '-Fuunit path'],
            test=False, wine=False)

    def compile(self, command, **kwargs):
        if str(command[1]).endswith(('embed_commands.py', 'build_id.py')):
            return
        output = next(arg[2:] for arg in command if arg.startswith('-o'))
        Path(output).write_bytes(b'compiled')

    def test_build_uses_argument_vector_isolated_units_and_copies_exact_catalog_and_dlls(self):
        extra = self.dlls / 'runtime.dll'
        extra.write_bytes(b'dependency')
        self.args.runtime_dll = [extra]
        with patch.object(builder.subprocess, 'run', side_effect=self.compile) as run:
            builder.build(self.args)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ['compiler with spaces', '-Xi', '-Fuunit path'])
        self.assertIn('-Twin64', command)
        self.assertIn('-B', command)
        self.assertIn('-FU' + str(self.args.output / 'units'), command)
        self.assertEqual(run.call_args.kwargs, dict(cwd=builder.ROOT, check=True))
        self.assertEqual((self.args.output / 'commands.json').read_bytes(), (builder.ROOT / 'commands.json').read_bytes())
        for source in [*(self.dlls / n for n in builder.DLL_NAMES), extra]:
            self.assertEqual((self.args.output / source.name).read_bytes(), source.read_bytes())

    def test_gitless_build_id_for_shared_checkout_and_archive(self):
        script = builder.ROOT / 'tools' / 'build_id.py'
        copied = self.root / 'tools' / script.name
        copied.parent.mkdir()
        copied.write_bytes(script.read_bytes())
        (self.root / '.git').mkdir()
        output = self.root / 'scucommit.inc'
        env = dict(os.environ, PATH='', SCU_BUILD_COMMIT='9FD87C7')
        def run():
            return subprocess.run([sys.executable, str(copied), str(output)],
                                  env=env, capture_output=True, text=True)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(output.read_text().strip(), "'9fd87c7'")
        git = self.root / '.git'
        digest = 'beef123' + '0' * 33
        (git / 'HEAD').write_text(digest)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(output.read_text().strip(), "'beef123'")
        (git / 'HEAD').write_text('ref: refs/heads/master')
        branch = git / 'refs' / 'heads' / 'master'
        branch.parent.mkdir(parents=True)
        branch.write_text(digest)
        self.assertEqual(run().returncode, 0)
        self.assertEqual(output.read_text().strip(), "'beef123'")
        branch.unlink()
        (git / 'packed-refs').write_text(digest + ' refs/heads/master\n')
        self.assertEqual(run().returncode, 0)
        self.assertEqual(output.read_text().strip(), "'beef123'")
        (git / 'HEAD').unlink()
        env['SCU_BUILD_COMMIT'] = 'not-a-commit'
        self.assertIn('must be a hexadecimal Git commit ID', run().stderr)
        copied.write_text(copied.read_text().replace('$Format:%h$', 'a123456'))
        self.assertEqual(run().returncode, 0)
        self.assertEqual(output.read_text().strip(), "'a123456'")

    def test_missing_runtime_is_rejected_before_compilation_or_output_creation(self):
        (self.dlls / builder.DLL_NAMES[-1]).unlink()
        with patch.object(builder.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'does not exist'):
                builder.build(self.args)
        run.assert_not_called()
        self.assertFalse(self.args.output.exists())

    def test_duplicate_runtime_names_are_case_insensitive(self):
        duplicate = self.root / 'SQLITE3.DLL'
        duplicate.write_bytes(b'duplicate')
        self.args.runtime_dll = [duplicate]
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            builder.build(self.args)
        self.assertFalse(self.args.output.exists())

    def test_compiler_failure_stops_before_catalog_and_test_execution(self):
        self.args.test = True
        def fail_compiler(command, **kwargs):
            if command[0] == self.args.fpc:
                raise subprocess.CalledProcessError(7, command)
        with patch.object(builder.subprocess, 'run', side_effect=fail_compiler) as run:
            with self.assertRaises(subprocess.CalledProcessError) as error:
                builder.build(self.args)
        self.assertEqual(error.exception.returncode, 7)
        self.assertEqual(run.call_count, 3)
        self.assertFalse((self.args.output / 'commands.json').exists())

    def test_success_without_executable_is_an_error(self):
        with patch.object(builder.subprocess, 'run'):
            with self.assertRaisesRegex(ValueError, 'did not produce'):
                builder.build(self.args)

    def test_tests_run_after_runtime_files_are_staged_and_failures_propagate(self):
        self.args.test = True
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            if str(command[1]).endswith(('embed_commands.py', 'build_id.py')):
                return
            if command[0] == self.args.fpc:
                return self.compile(command)
            self.assertTrue((self.args.output / 'commands.json').is_file())
            for name in builder.DLL_NAMES:
                self.assertTrue((self.args.output / name).is_file())
            self.assertEqual(Path(command[1]), builder.ROOT / 'tests/portable_cli.py')
            raise subprocess.CalledProcessError(1, command)
        with patch.object(builder.subprocess, 'run', side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                builder.build(self.args)
        self.assertEqual(len(calls), 4)

    def test_runtime_aliases_follow_loader_names_without_renaming_vendor_dlls(self):
        (self.dlls / 'libzstd.dll').rename(self.dlls / 'zstd.dll')
        (self.dlls / 'libcrypto-3.dll').rename(self.dlls / 'libcrypto-3-x64.dll')
        self.args.test = True
        def run(command, **kwargs):
            if command[0] == self.args.fpc:
                self.compile(command)
        with patch.object(builder.subprocess, 'run', side_effect=run):
            builder.build(self.args)
        self.assertTrue((self.args.output / 'zstd.dll').is_file())
        self.assertTrue((self.args.output / 'libcrypto-3-x64.dll').is_file())
        self.assertFalse((self.args.output / 'libzstd.dll').exists())

    def test_stale_preferred_dll_cannot_shadow_the_selected_runtime(self):
        self.args.output.mkdir(parents=True)
        (self.args.output / 'libcrypto-3-x64.dll').write_bytes(b'stale')
        with patch.object(builder.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Conflicting previously staged DLL'):
                builder.build(self.args)
        run.assert_not_called()

    def test_main_reports_failures_and_preserves_nonzero_status(self):
        for error, code, message in [
            (subprocess.CalledProcessError(7, ['compiler']), 7, 'exit 7'),
            (FileNotFoundError('missing compiler'), 1, 'missing compiler'),
        ]:
            with self.subTest(error=error):
                report = io.StringIO()
                with patch.object(sys, 'argv', ['build_windows.py']), patch.object(sys, 'stderr', report):
                    with patch.object(builder, 'build', side_effect=error):
                        self.assertEqual(builder.main(), code)
                self.assertIn(message, report.getvalue())

    def test_gui_build_uses_native_widgetset_local_projects_and_checks_after_build(self):
        self.args.gui = self.args.gui_test = True
        self.args.fpc = 'fpc'
        calls = []
        templates = {name: (builder.ROOT / name).read_bytes() for name in ['gui/scu_gui.lpi', 'tests/gui_check.lpi']}
        def run(command, **kwargs):
            calls.append(command)
            if command[0] == self.args.fpc:
                self.compile(command)
            elif command[0] == self.args.lazbuild:
                self.assertFalse(any(arg.startswith('--compiler=') for arg in command))
                self.assertIn('--widgetset=win32', command)
                self.assertIn('--os=win64', command)
                project = ET.parse(command[-1]).getroot()
                target = Path(project.find('CompilerOptions/Target/Filename').get('Value'))
                self.assertEqual(target.parent, self.args.output)
                unit = Path(project.find('ProjectOptions/Units/Unit0/Filename').get('Value'))
                self.assertTrue(unit.is_file())
                target.write_bytes(b'GUI executable')
        with patch.object(builder.subprocess, 'run', side_effect=run):
            builder.build(self.args)
        self.assertEqual(len(calls), 7)
        self.assertEqual(Path(calls[-1][1]), builder.ROOT / 'tests/gui_integration.py')
        self.assertIn('--gui-check', calls[-1])
        for name, content in templates.items():
            self.assertEqual((builder.ROOT / name).read_bytes(), content)

    def test_gui_test_requires_gui_before_compiling(self):
        self.args.gui_test = True
        with patch.object(builder.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, '--gui-test requires --gui'):
                builder.build(self.args)
        run.assert_not_called()

    def test_gui_failure_stops_before_test_execution(self):
        self.args.gui = self.args.gui_test = True
        def run(command, **kwargs):
            if command[0] == self.args.fpc:
                self.compile(command)
            elif command[0] == self.args.lazbuild:
                raise subprocess.CalledProcessError(8, command)
        with patch.object(builder.subprocess, 'run', side_effect=run) as execute:
            with self.assertRaises(subprocess.CalledProcessError):
                builder.build(self.args)
        self.assertEqual(execute.call_count, 5)

    def test_wine_without_test_is_rejected(self):
        self.args.wine = True
        with self.assertRaisesRegex(ValueError, 'requires --test'):
            builder.build(self.args)

    def test_build_can_reuse_app_local_runtime_without_copying_onto_itself(self):
        self.args.output = self.dlls
        self.args.test = True
        self.args.wine = True
        with patch.object(builder.subprocess, 'run') as run:
            (self.dlls / 'scu.exe').write_bytes(b'previous compiler output')
            builder.build(self.args)
        suites = [call.args[0] for call in run.call_args_list if call.args[0][-1] == '--wine']
        self.assertEqual([Path(command[1]).stem for command in suites],
                         ['portable_cli'] + [suite for _, suite in builder.PLATFORM_SUITES])
        self.assertEqual(Path(suites[1][2]).name, 'export_names_probe.exe')
        self.assertEqual((self.dlls / 'sqlite3.dll').read_bytes(), b'sqlite3.dll')


if __name__ == '__main__':
    unittest.main()
