#!/usr/bin/env python3
"""Non-network fixtures for namespace lab admission. Never run the experiment."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('lab', Path(__file__).with_name('lab-outer-awg-identity.py'))
lab = importlib.util.module_from_spec(spec); spec.loader.exec_module(lab)


class AdmissionTests(unittest.TestCase):
    def test_each_shared_namespace_refuses_before_tools(self):
        for shared in ('net', 'user', 'mnt'):
            with self.subTest(shared=shared):
                with patch.object(lab, 'namespace', side_effect=lambda kind: kind if kind == shared else 'private-' + kind), patch.object(lab, 'parent_namespace', side_effect=lambda pid, kind: kind), patch.object(lab.os, 'getppid', return_value=42):
                    with patch.object(lab, 'run') as tools:
                        with self.assertRaises(RuntimeError): lab.inside(42, 'iptables')
                        tools.assert_not_called()

    def test_forged_inside_parent_refuses_before_all_tools(self):
        with patch.object(lab.os, 'getppid', return_value=42), patch.object(lab, 'run') as commands:
            with self.assertRaises(RuntimeError): lab.inside(43, 'iptables')
            commands.assert_not_called()

    def test_direct_inside_on_host_refuses_before_all_tools(self):
        # Real parent PID and real shared namespaces: a forged direct entrypoint
        # must never reach mount/ip/iptables, even with a valid executable path.
        with patch.object(lab, 'run') as commands:
            with self.assertRaises(RuntimeError): lab.inside(lab.os.getppid(), '/usr/sbin/iptables')
            commands.assert_not_called()

    def test_unexpected_datagram_cannot_pass_negative_probe(self):
        self.assertFalse(lab.delivery_result('{"received":false}', 'expected'))
        self.assertTrue(lab.delivery_result('{"received":true,"payload":"expected"}', 'expected'))
        for value in ['{"received":true,"payload":"BLOCKED"}', '{"received":true,"payload":"other"}']:
            with self.assertRaises(AssertionError): lab.delivery_result(value, 'expected')

    def test_timeout_kills_only_owned_experiment_group(self):
        with patch.object(lab.subprocess, 'Popen') as child, patch.object(lab.os, 'killpg') as kill:
            child.return_value.pid = 12345
            child.return_value.wait.side_effect = [lab.subprocess.TimeoutExpired('fixture', 90), 0]
            with self.assertRaises(lab.subprocess.TimeoutExpired): lab.launch_isolated(['unshare'])
            kill.assert_called_once_with(12345, lab.signal.SIGKILL)
            self.assertTrue(child.call_args.kwargs['start_new_session'])

    def test_no_flag_never_launches(self):
        with patch.object(sys, 'argv', ['lab']), patch.object(lab.subprocess, 'run') as commands:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                lab.main()
            self.assertEqual(raised.exception.code, 2); commands.assert_not_called()

    def test_missing_dependencies_never_launches(self):
        with patch.object(sys, 'argv', ['lab', '--run-isolated']), patch.object(lab.shutil, 'which', return_value=None):
            with patch.object(lab.subprocess, 'run') as commands:
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised: lab.main()
                self.assertEqual(raised.exception.code, 77); commands.assert_not_called()

    def test_launcher_only_runs_unshare_with_all_barriers(self):
        with patch.object(sys, 'argv', ['lab', '--run-isolated']), patch.object(lab.shutil, 'which', return_value='/fixture/tool'):
            with patch.object(lab, 'namespace', side_effect=lambda kind: 'parent-' + kind):
                with patch.object(lab.subprocess, 'Popen') as commands:
                    commands.return_value.wait.return_value = 77
                    with self.assertRaises(SystemExit) as raised: lab.main()
                    self.assertEqual(raised.exception.code, 77)
                    args = commands.call_args.args[0]
                    self.assertEqual(args[0], 'unshare')
                    self.assertTrue(commands.call_args.kwargs['start_new_session'])
                    for flag in ['--user', '--map-root-user', '--net', '--mount', '--inside']:
                        self.assertIn(flag, args)
                    self.assertEqual(args[-2], str(lab.os.getpid()))


if __name__ == '__main__': unittest.main(verbosity=2)
