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
                with patch.object(lab, 'namespace', side_effect=lambda kind: kind if kind == shared else 'private-' + kind):
                    with patch.object(lab, 'run') as tools:
                        with self.assertRaises(RuntimeError): lab.inside('net', 'user', 'mnt', 'iptables')
                        tools.assert_not_called()

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
                with patch.object(lab.subprocess, 'run') as commands:
                    commands.return_value.returncode = 77
                    with self.assertRaises(SystemExit) as raised: lab.main()
                    self.assertEqual(raised.exception.code, 77)
                    args = commands.call_args.args[0]
                    self.assertEqual(args[0], 'unshare')
                    for flag in ['--user', '--map-root-user', '--net', '--mount', '--inside']:
                        self.assertIn(flag, args)
                    self.assertIn('parent-net', args); self.assertIn('parent-user', args); self.assertIn('parent-mnt', args)


if __name__ == '__main__': unittest.main(verbosity=2)
