#!/usr/bin/env python3
"""Isolated UDP classifier experiment for #22, never real AWG acceptance."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve()


def namespace(kind):
    return os.readlink('/proc/self/ns/' + kind)


def admit(parent_net, parent_user, parent_mount):
    if (namespace('net') == parent_net or namespace('user') == parent_user or
            namespace('mnt') == parent_mount):
        raise RuntimeError('refusing: private network, user AND mount namespaces are required')


def run(*args):
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=15).stdout.strip()


def inside(parent_net, parent_user, parent_mount, iptables):
    # No mutation may precede this barrier. Nested nodes stay inside this private netns tree.
    admit(parent_net, parent_user, parent_mount)
    # Prevent xtables lock-file creation in the caller's /run; no propagation.
    run('mount', '--make-rprivate', '/')
    run('mount', '-t', 'tmpfs', 'tmpfs', '/run')
    nodes = []
    def ip(*args): return run('ip', *args)
    def node(pid, *args): return run('nsenter', '-t', str(pid), '-n', *args)
    def rule(*args): return run(iptables, '-M', '/bin/false', '-w', '2', *args)
    report = {'kind': 'UDP classifier surrogate; NOT real AWG/security acceptance',
              'private_netns': namespace('net'), 'private_userns': namespace('user'), 'probes': []}
    try:
        # Probe kernel/backend only after namespace admission. Missing capability => SKIP.
        rule('-t', 'mangle', '-S')
        ip('link', 'set', 'lo', 'up')
        ip('link', 'add', 'br0', 'type', 'bridge'); ip('link', 'set', 'br0', 'up')
        ip('addr', 'add', '172.29.0.1/24', 'dev', 'br0')
        for name, address in [('awg', '172.29.0.2'), ('attacker', '172.29.0.3'), ('wan', '172.20.0.2')]:
            process = subprocess.Popen(['unshare', '--net', sys.executable, str(HERE), '--hold'])
            nodes.append(process)
            for _ in range(100):
                if os.readlink('/proc/' + str(process.pid) + '/ns/net') != namespace('net'): break
                if process.poll() is not None: raise RuntimeError('nested namespace failed')
                time.sleep(.01)
            else: raise RuntimeError('nested namespace timeout')
            root, peer = name + '-r', name + '-n'
            ip('link', 'add', root, 'type', 'veth', 'peer', 'name', peer)
            ip('link', 'set', peer, 'netns', str(process.pid))
            ip('link', 'set', root, 'up')
            if name != 'wan': ip('link', 'set', root, 'master', 'br0')
            else: ip('addr', 'add', '172.20.0.1/24', 'dev', root)
            node(process.pid, 'ip', 'link', 'set', 'lo', 'up')
            node(process.pid, 'ip', 'link', 'set', peer, 'up')
            node(process.pid, 'ip', 'addr', 'add', address + '/24', 'dev', peer)
            gateway = '172.20.0.1' if name == 'wan' else '172.29.0.1'
            node(process.pid, 'ip', 'route', 'add', 'default', 'via', gateway)
        # This proc sysctl is network-namespace scoped; admission already proved isolation.
        Path('/proc/sys/net/ipv4/ip_forward').write_text('1\n')
        rule('-P', 'FORWARD', 'DROP')
        rule('-A', 'FORWARD', '-m', 'mark', '--mark', '0x88', '-j', 'ACCEPT')
        awg, attacker, wan = [p.pid for p in nodes]
        node(wan, 'ip', 'addr', 'add', '172.20.0.3/24', 'dev', 'wan-n')
        def classifier(narrow):
            rule('-t', 'mangle', '-F', 'PREROUTING')
            args = ['-t', 'mangle', '-A', 'PREROUTING', '-s', '172.29.0.0/24', '-p', 'udp', '--sport', '39551']
            if narrow: args += ['-m', 'physdev', '--physdev-in', 'awg-r']
            rule(*args, '-j', 'MARK', '--set-mark', '0x88')
        def probe(label, sender, expected, endpoint='172.20.0.2', source=''):
            receiver = "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('" + endpoint + "',54321)); s.settimeout(1); print('READY',flush=True);\ntry: print(s.recv(256).decode(),flush=True)\nexcept socket.timeout: print('BLOCKED',flush=True)"
            listener = subprocess.Popen(['nsenter', '-t', str(wan), '-n', sys.executable, '-c', receiver], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if listener.stdout.readline().strip() != 'READY':
                listener.kill(); listener.communicate(); raise RuntimeError('receiver setup failed')
            try:
                node(sender, sys.executable, '-c', "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind((" + repr(source) + ",39551)); s.sendto(" + repr(label.encode()) + ",(" + repr(endpoint) + ",54321))")
                output, errors = listener.communicate(timeout=5)
            finally:
                if listener.poll() is None: listener.kill(); listener.communicate()
            if listener.returncode: raise RuntimeError('receiver failed: ' + errors)
            delivered = output.strip() == label
            report['probes'].append({'name': label, 'delivered': delivered, 'expected': expected})
            if delivered != expected: raise AssertionError(label + ': unexpected delivery')
        classifier(False)
        probe('current-awg-surrogate', awg, True)
        probe('current-attacker-same-port-EXPOSURE', attacker, True)
        classifier(True)
        probe('candidate-awg-surrogate', awg, True)
        probe('candidate-attacker-same-port', attacker, False)
        node(attacker, 'ip', 'addr', 'add', '172.29.0.2/32', 'dev', 'attacker-n')
        probe('candidate-attacker-spoofed-source', attacker, False, source='172.29.0.2')
        probe('candidate-second-peer', awg, True, endpoint='172.20.0.3')
        classifier(True)
        probe('candidate-reconcile', awg, True)
        probe('candidate-reconcile-attacker', attacker, False)
        rule('-t', 'mangle', '-F', 'PREROUTING')
        probe('missing-classifier-fails-closed', awg, False)
        report['rules_after_probe'] = rule('-S')
        print(json.dumps(report, indent=2))
    finally:
        # Destroy only processes spawned inside the admitted namespace. All devices/rules
        # die with these namespaces; there is no host cleanup or host iptables command.
        for process in nodes:
            if process.poll() is None: process.terminate()
        for process in nodes:
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--inside', nargs=4, metavar=('PARENT_NET', 'PARENT_USER', 'PARENT_MOUNT', 'IPTABLES'))
    parser.add_argument('--hold', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.hold:
        time.sleep(120); return
    if args.inside:
        inside(*args.inside); return
    if not args.run_isolated:
        parser.error('--run-isolated is required; no implicit network actions')
    for tool in ['unshare', 'nsenter', 'ip', 'mount']:
        if not shutil.which(tool):
            print('SKIP: missing ' + tool); sys.exit(77)
    iptables = os.environ.get('AMG_LAB_IPTABLES') or shutil.which('iptables')
    if not iptables:
        print('SKIP: missing iptables; no host packages are installed'); sys.exit(77)
    # Launcher does not call ip/iptables/sysctl. Even overridden binary executes only
    # after child admission proves a different private network AND user namespace.
    result = subprocess.run(['unshare', '--user', '--map-root-user', '--net', '--mount', sys.executable,
                             str(HERE), '--inside', namespace('net'), namespace('user'), namespace('mnt'), iptables], timeout=90)
    sys.exit(result.returncode)


if __name__ == '__main__':
    try: main()
    except subprocess.CalledProcessError as error:
        print('SKIP: isolated kernel/backend/tool unavailable: ' + (error.stderr or str(error)), file=sys.stderr)
        sys.exit(77)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print('REFUSED/INCOMPLETE: ' + str(error), file=sys.stderr); sys.exit(1)
