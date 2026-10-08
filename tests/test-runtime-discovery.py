#!/usr/bin/env python3
"""Fixture-only runtime identity tests; never invokes real systemctl or Docker."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / 'install.sh').read_text()
HELPER = SOURCE.split("<<'PY_RUNTIME'\n", 1)[1].split('\nPY_RUNTIME', 1)[0]


class BindingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.proc = self.base / 'proc'; self.proc.mkdir()
        self.home = self.base / 'home'; self.home.mkdir()
        self.config = self.home / 'config.yaml'
        self.config.write_text('dns:\n  enable: true\ntun:\n  enable: true\n')
        self.argv = ['mihomo', '-d', str(self.home)]
        self.service = 'MainPID=11\nActiveState=active\nExecStart={ path=/usr/bin/mihomo ; argv[]=mihomo -d ' + str(self.home) + ' ; }\nLoadState=loaded'
        self.containers = []
        self.namespace = {'__name__': 'fixture'}
        exec(compile(HELPER, '<embedded runtime>', 'exec'), self.namespace)
        self.namespace['PROC'] = self.proc
        self.namespace['command'] = self.command
        self.mock_run = patch.object(subprocess, 'run', side_effect=self.service_run)
        self.mock_run.start(); self.addCleanup(self.mock_run.stop)
        self.pid(11)

    def pid(self, pid):
        path = self.proc / str(pid); path.mkdir(exist_ok=True)
        for name, target in [('exe', '/usr/bin/mihomo'), ('cwd', str(self.home)), ('root', '/')]:
            link = path / name
            if link.is_symlink(): link.unlink()
            link.symlink_to(target)
        (path / 'cmdline').write_bytes(b'\0'.join(a.encode() for a in self.argv) + b'\0')
        (path / 'environ').write_bytes(b'HOME=/root\0')
        (path / 'stat').write_text(str(pid) + ' (mihomo (worker)) ' + ' '.join(['S'] + ['0'] * 18 + ['1234'] + ['0'] * 5))
        return path

    def command(self, *args):
        self.assertEqual(args[0], 'docker')
        if args[1] == 'ps': return '\n'.join(c['Id'] for c in self.containers)
        if args[1] == 'inspect': return json.dumps([c for c in self.containers if c['Id'] == args[2]])
        self.fail(str(args))

    def service_run(self, args, **kwargs):
        self.assertEqual(args[:3], ['systemctl', 'show', 'mihomo.service'])
        return types.SimpleNamespace(stdout=self.service, returncode=0)

    def discover(self): return self.namespace['discover']()

    def refuse(self):
        with self.assertRaises((ValueError, OSError)):
            self.discover()

    def verify(self, original, mode='verify'):
        with patch.object(sys, 'argv', ['runtime', mode, json.dumps(original)]):
            self.namespace['main']()

    def test_systemd_d_ignores_backup_configs_and_reinstall(self):
        (self.base / 'backup').mkdir(); (self.base / 'backup/config.yaml').write_text('unrelated')
        result = self.discover()
        self.assertEqual(result['path'], str(self.config)); self.verify(result)
        self.assertEqual(self.discover(), result)

    def test_systemd_f_absolute(self):
        custom = self.base / 'custom.yml'; custom.write_text('custom')
        self.argv = ['mihomo', '-f', str(custom)]; self.pid(11)
        self.assertEqual(self.discover()['path'], str(custom))

    def test_relative_f_uses_cwd_not_d(self):
        self.argv = ['mihomo', '-d', '/different-home', '-f=config.yaml']; self.pid(11)
        self.assertEqual(self.discover()['path'], str(self.config))

    def test_relative_d_uses_cwd(self):
        self.argv = ['mihomo', '-d', '.']; self.pid(11)
        self.assertEqual(self.discover()['path'], str(self.config))

    def test_multiple_processes(self): self.pid(12); self.refuse()
    def test_no_runtime_initial_install(self): (self.proc / '11/exe').unlink(); self.refuse()
    def test_unbound_process(self): self.service = 'MainPID=12\nActiveState=active'; self.refuse()
    def test_inactive_service(self): self.service = 'MainPID=11\nActiveState=inactive'; self.refuse()

    def test_ambiguous_flags_and_unsupported_forms(self):
        for tail in [['-d', str(self.home), '-d', str(self.home)], ['-f'], ['-f', '-'],
                     ['-config', 'YWJj'], ['-age-secret-key', 'x'], ['-unknown'], [],
                     ['-d', str(self.home), 'positional'], ['-t', '-d', str(self.home)]]:
            with self.subTest(args=tail):
                self.argv = ['mihomo'] + tail; self.pid(11); self.refuse()

    def test_environment_config_refused(self):
        for key in ['CLASH_CONFIG_STRING', 'CLASH_CONFIG_FILE', 'CLASH_HOME_DIR']:
            (self.proc / '11/environ').write_bytes((key + '=different\0').encode()); self.refuse()

    def test_symlink_and_hardlink_refused(self):
        original = self.base / 'original'; self.config.rename(original); self.config.symlink_to(original)
        self.refuse(); self.config.unlink(); os.link(original, self.config); self.refuse()

    def test_runtime_changes_refused(self):
        for field in ['stat', 'cmdline', 'environ']:
            with self.subTest(field=field):
                self.pid(11); result = self.discover()
                p = self.proc / '11' / field
                content = p.read_bytes()
                if field == 'stat': content = content.replace(b'1234', b'5678')
                elif field == 'cmdline': content = content.replace(b'-d', b'--d')
                else: content += b'EXTERNAL=changed\0'
                p.write_bytes(content)
                with self.assertRaises(ValueError): self.verify(result)

    def test_execstart_change_refused(self):
        result = self.discover(); self.service += '\nChanged=1'
        with self.assertRaises(ValueError): self.verify(result)

    def test_config_edit_and_same_byte_inode_change_refused(self):
        result = self.discover(); self.config.write_text('admin changed')
        with self.assertRaises(ValueError): self.verify(result)
        result = self.discover(); new = self.base / 'new'; new.write_bytes(self.config.read_bytes()); new.replace(self.config)
        with self.assertRaises(ValueError): self.verify(result)

    def test_runtime_only_check_after_our_atomic_patch(self):
        result = self.discover(); new = self.base / 'new'; new.write_text('patched'); new.replace(self.config)
        self.verify(result, 'runtime')

    def docker(self):
        self.argv = ['mihomo', '-d', '/config']; path = self.pid(11)
        (path / 'root').unlink(); root = self.base / 'container-root'; root.mkdir()
        (root / 'config').symlink_to(self.home, target_is_directory=True)
        (path / 'root').symlink_to(root, target_is_directory=True)
        self.service = 'LoadState=not-found\nMainPID=0\nActiveState=inactive'
        container = {'Id': 'a'*64, 'Path': 'mihomo', 'Args': self.argv[1:],
                     'State': {'Running': True, 'Pid': 11, 'StartedAt': 'initial'},
                     'Mounts': [{'Type': 'bind', 'Source': str(self.home), 'Destination': '/config', 'RW': True}]}
        self.containers = [container]
        return container

    def test_docker_directory_bind_and_exact_id(self):
        container = self.docker(); result = self.discover()
        self.assertEqual(result['path'], str(self.config)); self.assertEqual(result['controller']['id'], container['Id'])
        self.verify(result)

    def test_docker_f_and_args_agreement(self):
        container = self.docker(); self.argv = ['mihomo', '-f', '/config/config.yaml']; self.pid(11)
        # pid() resets root; restore container mapping.
        root = self.proc / '11/root'; root.unlink(); root.symlink_to(self.base / 'container-root')
        container['Args'] = self.argv[1:]
        self.assertEqual(self.discover()['path'], str(self.config))
        container['Args'] = ['-f', '/wrong']; self.refuse()

    def test_docker_single_file_bind_readonly_volume_overlap_refused(self):
        container = self.docker(); mount = container['Mounts'][0]
        original = dict(mount)
        for changed in [{'Source': str(self.config), 'Destination': '/config/config.yaml'}, {'RW': False}, {'Type': 'volume'}]:
            container['Mounts'] = [dict(original, **changed)]; self.refuse()
        container['Mounts'] = [original, dict(original)]; self.refuse()

    def test_docker_mapping_and_runtime_change_refused(self):
        container = self.docker(); result = self.discover()
        container['State']['StartedAt'] = 'restarted'
        with self.assertRaises(ValueError): self.verify(result)
        container['Mounts'][0]['Source'] = str(self.base); self.refuse()

    def test_docker_same_inode_other_device_refused(self):
        self.docker()
        visible = self.proc / '11/root/config/config.yaml'
        original_stat = Path.stat
        def stat_with_other_device(path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            if path == visible:
                fields = list(result); fields[2] += 1
                return os.stat_result(fields)
            return result
        with patch.object(Path, 'stat', stat_with_other_device):
            self.refuse()

    def test_two_controllers_refused(self):
        self.docker(); self.service = 'MainPID=11\nActiveState=active'; self.refuse()

    def test_preflight_before_all_writes(self):
        admission = SOURCE.split('# BEGIN MIHOMO_RUNTIME_BINDING\n', 1)[1].split('# END MIHOMO_RUNTIME_BINDING', 1)[0]
        admission = admission.replace("PROC = Path('/proc')", 'PROC = Path(' + repr(str(self.base / 'empty-proc')) + ')')
        (self.base / 'empty-proc').mkdir()
        result = subprocess.Popen(['bash', '-c', 'set -e\n' + admission], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = result.communicate(timeout=20)
        self.assertNotEqual(result.returncode, 0); self.assertIn(b'exactly one', err)
        self.assertLess(SOURCE.index('# BEGIN MIHOMO_RUNTIME_BINDING'), SOURCE.index('mkdir -p "$STATE_DIR"'))
        self.assertNotIn('MIHOMO_CONFIG=$(find ', SOURCE)
        self.assertIn('mihomo_runtime_binding verify "$MIHOMO_RUNTIME"\nmkdir -p', SOURCE)

    def test_patcher_identity_guard_prevents_replace(self):
        fragment = SOURCE.split('    # BEGIN MIHOMO_CONFIG_PATCH\n', 1)[1].split('    patch_mihomo_config "$MIHOMO_CONFIG"', 1)[0]
        runner = self.base / 'patcher.sh'
        runner.write_text('set -e\nFAKE_IP_RANGE=198.18.0.0/16\nMIHOMO_RUNTIME=fixture\nmihomo_runtime_binding() { return 1; }\n' + fragment + '\npatch_mihomo_config "$1"\n')
        before = self.config.read_bytes()
        # Popen bypasses the mocked service-only subprocess.run.
        result = subprocess.Popen(['bash', str(runner), str(self.config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        result.communicate(timeout=20)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(self.config.read_bytes(), before)


if __name__ == '__main__': unittest.main(verbosity=2)
