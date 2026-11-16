#!/usr/bin/env python3
"""Shared editor plus Windows key encoding, history and session-signal checks."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROBE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else 'build/terminal_probe').resolve()
WINE = '--wine' in sys.argv
if WINE:
    sys.argv.remove('--wine')
WINDOWS = WINE or os.name == 'nt'


def argument(value):
    if WINE and isinstance(value, Path):
        return 'Z:' + str(value.absolute()).replace('/', '\\')
    return str(value)


def command(*args):
    return (['wine', str(PROBE)] if WINE else [str(PROBE)]) + [argument(value) for value in args]


def text(value):
    return 'text ' + value.encode().hex()


def key(name):
    return 'key ' + name


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state-日本語'
        self.env = {**os.environ, 'XDG_STATE_HOME': str(self.state),
                    'LOCALAPPDATA': argument(self.state), 'SCU_TEST_STATE': argument(self.state)}

    def run_probe(self, *args, error=None, **kwargs):
        result = subprocess.run(command(*args), capture_output=True, env=self.env, timeout=15, **kwargs)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
        return result

    def editor(self, actions, expected=None, error=None):
        script = self.root / 'input.txt'
        script.write_text('\n'.join(actions) + '\n')
        result = self.run_probe('editor', script, error=error)
        if expected is not None:
            lines = [bytes.fromhex(line[5:].decode()).decode() for line in result.stdout.splitlines() if line.startswith(b'line=')]
            self.assertEqual(lines, [expected])
        return result

    def history(self):
        result = self.run_probe('history')
        return [bytes.fromhex(line[8:].decode()).decode() for line in result.stdout.splitlines() if line.startswith(b'history=')]

    def test_cursor_navigation_insert_delete_home_end_and_backspace(self):
        self.editor([text('abc'), key('LEFT'), key('LEFT'), text('X'), key('DELETE'),
                     key('END'), key('BACK'), key('ENTER')], 'aX')

    def test_control_editing_and_word_navigation(self):
        self.editor([text('bad first second'), key('CTRL_LEFT'), key('CTRL_K'),
                     key('CTRL_U'), text('ok'), key('ENTER')], 'ok')

    def test_unicode_combining_wide_and_surrogate_characters_are_editable(self):
        self.editor([text('界e\u0301😀'), key('BACK'), key('BACK'), key('HOME'), text('Z'),
                     key('END'), key('BACK'), key('ENTER')], 'Z')

    def test_history_survives_process_restart_and_can_be_edited(self):
        self.run_probe('history-add', 'display_deck alpha')
        self.run_probe('history-add', 'display_deck beta')
        self.editor([key('UP'), key('HOME'), text('#'), key('END'), key('ENTER')], '#display_deck beta')
        self.assertEqual(self.history(), ['display_deck alpha', 'display_deck beta', '#display_deck beta'])

    def test_history_draft_is_restored(self):
        self.run_probe('history-add', 'old command')
        self.editor([text('draft'), key('UP'), key('DOWN'), key('ENTER')], 'draft')

    def test_reverse_search_match_is_editable_before_execution(self):
        self.run_probe('history-add', 'display_deck alpha')
        self.run_probe('history-add', 'display_deck beta')
        self.editor([key('CTRL_R'), text('alpha'), key('ENTER'), key('END'),
                     text(' changed'), key('ENTER')], 'display_deck alpha changed')

    def test_tab_completion_uses_the_shared_editor(self):
        self.editor([text('disd'), key('TAB'), key('ENTER')], 'display_deck ')

    def test_completion_pagination_and_resize_preserve_the_command_line(self):
        result = self.editor([text('choice_'), key('TAB'), key('TAB'), 'resize', text('q'),
                              text('01'), key('ENTER')], 'choice_01')
        self.assertIn(b'--More--', result.stderr)

    def test_ctrl_c_cancels_input_without_recording_history(self):
        result = self.editor([text('never executed'), key('CTRL_C')], error=b'Command cancelled.')
        self.assertEqual(result.stderr.count(b'Command cancelled.'), 1)
        self.assertEqual(self.history(), [])

    def test_signal_cancellation_and_priority(self):
        result = self.editor([text('never executed'), 'signal'], error=b'Command cancelled.')
        self.assertEqual(result.stderr.count(b'Command cancelled.'), 1)
        self.assertEqual(self.history(), [])
        result = self.run_probe('signals')
        self.assertIn(b'clear=1 pending=0', result.stdout)
        self.assertIn(b'ending=1 clear=0 pending=15', result.stdout)

    def test_session_interrupt_survives_lock_scope_then_clears_once(self):
        result = self.run_probe('scope', self.root / 'library.lock')
        self.assertEqual(result.stdout.count(b'cancelled'), 1)
        self.assertIn(b'pending=2 clear=1', result.stdout)
        self.assertIn(b'reacquired', result.stdout)

    def test_empty_line_ctrl_d_is_eof(self):
        result = self.editor([key('CTRL_D')])
        self.assertIn(b'eof', result.stdout)
        self.assertEqual(self.history(), [])

    @unittest.skipUnless(WINDOWS, 'Native Windows console event and mode APIs')
    def test_native_console_editing_completion_history_and_mode_restoration(self):
        if WINE:
            self.skipTest('Headless Wine cannot provide an isolated native Windows console.')
        self.run_probe('history-add', 'older command')
        cases = [([text('abc'), key('LEFT'), key('BACK'), text('X'), key('ENTER')], 'aXc'),
                 ([text('disd'), key('TAB'), key('ENTER')], 'display_deck '),
                 ([key('UP'), key('END'), text(' edited'), key('ENTER')], 'older command edited')]
        for actions, expected in cases:
            script = self.root / 'native-input.txt'
            script.write_text('\n'.join(actions) + '\n')
            result = self.run_probe('native-console', script, creationflags=subprocess.CREATE_NEW_CONSOLE)
            self.assertIn(b'console-restored', result.stdout)
            self.assertIn(b'line=' + expected.encode().hex().upper().encode(), result.stdout)

    @unittest.skipUnless(WINDOWS, 'Native Windows console cancellation')
    def test_native_console_ctrl_c_discards_line_and_restores_modes(self):
        if WINE:
            self.skipTest('Headless Wine cannot provide an isolated native Windows console.')
        script = self.root / 'native-input.txt'
        script.write_text('\n'.join([text('never executed'), key('CTRL_C')]) + '\n')
        result = self.run_probe('native-console', script, creationflags=subprocess.CREATE_NEW_CONSOLE,
                                error=b'Command cancelled.')
        self.assertIn(b'console-restored', result.stdout)
        self.assertEqual(result.stderr.count(b'Command cancelled.'), 1)
        self.assertEqual(self.history(), [])

    def test_redirected_command_output_preserves_bytes_and_lf(self):
        result = self.run_probe('output')
        self.assertEqual(result.stdout, bytes(range(256)) + b'end\n')

    @unittest.skipUnless(WINDOWS, 'Windows console key records')
    def test_windows_key_repeat_altgr_surrogate_and_keyup_handling(self):
        result = self.run_probe('special-keys')
        values = dict(line.split(b'=', 1) for line in result.stdout.splitlines())
        self.assertEqual(bytes.fromhex(values[b'repeat'].decode()), b'aaa')
        self.assertEqual(values[b'release'], b'')
        self.assertEqual(bytes.fromhex(values[b'altgr'].decode()).decode(), '€')
        self.assertEqual(bytes.fromhex(values[b'alt'].decode()), b'\x1bb')
        self.assertEqual(bytes.fromhex(values[b'pair'].decode()).decode(), '😀')
        self.assertEqual(bytes.fromhex(values[b'unpaired'].decode()).decode(), '\ufffd')

    def test_unicode_cell_widths(self):
        result = self.run_probe('width', 'Ae\u0301界😀\u200d')
        self.assertEqual([int(value) for value in result.stdout.splitlines()], [1, 1, 0, 2, 2, 0])

    def test_redirected_input_keeps_crlf_lines_and_partial_final_line(self):
        result = subprocess.run(command('batch'), input=b'first\r\nsecond\nlast',
                                capture_output=True, env=self.env, timeout=15)
        if WINE and b'Could not inspect redirected input' in result.stderr and b'not supported' in result.stderr.lower():
            self.skipTest('Wine host pipes do not implement PeekNamedPipe.')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [b'line=6669727374', b'line=7365636F6E64', b'line=6C617374'])

    @unittest.skipUnless(WINDOWS, 'Windows cancellable redirected input')
    def test_ctrl_c_cancels_a_blocked_redirected_read(self):
        process = subprocess.Popen(command('batch-cancel'), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        try:
            process.wait(timeout=5)
            stdout, stderr = process.communicate(timeout=5)
            if WINE and b'Could not inspect redirected input' in stderr and b'not supported' in stderr.lower():
                self.skipTest('Wine host pipes do not implement PeekNamedPipe.')
            self.assertEqual(process.returncode, 1, stderr)
            self.assertEqual(stderr.count(b'Command cancelled.'), 1)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    @unittest.skipUnless(WINDOWS, 'Windows history-lock cancellation')
    def test_cancelled_history_save_is_not_swallowed_or_written(self):
        self.run_probe('history-add', 'original command')
        path = self.state / 'scu' / 'history.json.lock'
        holder = subprocess.Popen(command('hold-lock', path), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        try:
            self.assertEqual(holder.stdout.readline().strip(), b'locked')
            result = self.run_probe('history-cancel', error=b'Command cancelled.')
            self.assertNotIn(b'Could not save command history', result.stderr)
        finally:
            holder.communicate(b'continue\n', timeout=5)
        self.assertEqual(self.history(), ['original command'])

    def test_corrupt_history_is_reported_without_being_overwritten(self):
        self.run_probe('history-add', 'original command')
        path = self.state / 'scu' / 'history.json'
        path.write_bytes(b'not JSON')
        result = self.run_probe('history-add', 'new command')
        self.assertIn(b'Could not load command history', result.stderr)
        self.assertEqual(path.read_bytes(), b'not JSON')

    @unittest.skipUnless(WINDOWS, 'Windows state-directory ACL validation')
    def test_history_refuses_a_directory_writable_by_everyone(self):
        self.run_probe('history-add', 'original command')
        path = self.state / 'scu' / 'history.json'
        original = path.read_bytes()
        self.run_probe('unsafe-state', self.state / 'scu')
        result = self.run_probe('history-add', 'new command')
        self.assertIn(b'private user-owned SCU state directory', result.stderr)
        self.assertEqual(path.read_bytes(), original)

    def test_unicode_history_is_persisted_in_the_selected_state_directory(self):
        # One editor restart verifies the actual scanner/serializer and state path.
        for value in ('déck α', 'last command'):
            self.run_probe('history-add', value)
        self.assertEqual(self.history(), ['déck α', 'last command'])
        history = self.state / 'scu' / 'history.json'
        self.assertTrue(history.exists())
        self.assertIn('déck', history.read_text())


if __name__ == '__main__':
    unittest.main()
