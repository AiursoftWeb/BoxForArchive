#!/usr/bin/env python3
"""Reconcile the local Box Swarm gateway without changing its IPv4 allocation."""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

STATE = Path('/var/lib/box-docker-network')
CONFIG = Path('/etc/docker/daemon.json')
PENDING = STATE / 'pending.json'


def run(*args, timeout=180):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=timeout).strip()


def docker(*args):
    return run('docker', *args)


def inspect(kind, *ids):
    return json.loads(docker(kind, 'inspect', *ids))


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    with temp.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def wait_for(check, message, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError(message)


def start_docker(transaction):
    if transaction['socket']:
        run('systemctl', 'start', 'docker.socket')
    run('systemctl', 'start', 'docker.service')
    wait_for(lambda: bool(docker('info', '--format', '{{.ID}}')), 'Docker did not become ready')


def gateway():
    networks = inspect('network', *docker('network', 'ls', '-q').split())
    return next((n for n in networks if n['Name'] == 'docker_gwbridge'), None)


def network_args(network):
    args = ['--driver', 'bridge']
    if network:
        for pool in network['IPAM']['Config']:
            args.extend(['--subnet', pool['Subnet']])
            if pool.get('Gateway'):
                args.extend(['--gateway', pool['Gateway']])
            if pool.get('IPRange'):
                args.extend(['--ip-range', pool['IPRange']])
        for key, value in (network['IPAM'].get('Options') or {}).items():
            args.extend(['--ipam-opt', f'{key}={value}'])
        for key, value in (network.get('Options') or {}).items():
            args.extend(['--opt', f'{key}={value}'])
        for key, value in (network.get('Labels') or {}).items():
            args.extend(['--label', f'{key}={value}'])
        if network['EnableIPv6']:
            args.append('--ipv6')
    else:
        args.extend(['--opt', 'com.docker.network.bridge.name=docker_gwbridge',
                     '--opt', 'com.docker.network.bridge.enable_icc=false',
                     '--opt', 'com.docker.network.bridge.enable_ip_masquerade=true'])
    return args


def detach_gateway():
    # Swarm recreates this sandbox asynchronously after Docker starts.
    active = docker('info', '--format', '{{.Swarm.LocalNodeState}}') == 'active'
    if active:
        wait_for(lambda: gateway() is not None, 'Swarm did not recreate its gateway')
    elif gateway() is None:
        return
    expected = {'ingress-sbox'} if active else set()
    stable = 0
    def empty_gateway():
        nonlocal stable
        endpoints = set((gateway() or {}).get('Containers', {}))
        stable = stable + 1 if endpoints == expected else 0
        return stable >= 3
    wait_for(empty_gateway, 'Gateway still has workload endpoints')
    current = gateway()
    if current:
        if 'ingress-sbox' in current.get('Containers', {}):
            docker('network', 'disconnect', '--force', 'docker_gwbridge', 'gateway_ingress-sbox')
        docker('network', 'rm', 'docker_gwbridge')


def restore(transaction):
    print('Recovering the previous gateway and node availability.', flush=True)
    # Restoration also runs on the next invocation after a killed process or reboot.
    try:
        start_docker(transaction)
    except (subprocess.SubprocessError, RuntimeError):
        save(CONFIG, transaction['config'])
        start_docker(transaction)
    if transaction['rebuilding']:
        if transaction['node']:
            docker('node', 'update', '--availability', 'drain', transaction['node'])
            wait_for(lambda: not docker('ps', '-q', '--filter', 'label=com.docker.swarm.service.id'),
                     'Swarm workloads did not stop for recovery')
        current = gateway()
        if current is None or not current.get('Containers'):
            # A killed operation may have already detached the ingress sandbox.
            run('systemctl', 'restart', 'docker.service')
            start_docker(transaction)
        detach_gateway()
        if transaction['gateway']:
            docker('network', 'create', *network_args(transaction['gateway']), 'docker_gwbridge')
        run('systemctl', 'restart', 'docker.service')
        start_docker(transaction)
    if transaction['node']:
        docker('node', 'update', '--availability', transaction['availability'], transaction['node'])
    PENDING.unlink()
    print('Previous network and node availability restored.', flush=True)


def is_allocation(network):
    return (network['Name'].startswith('box-bridge-allocation') and network['Driver'] == 'bridge' and
            (network.get('Labels') or {}).get('aiursoft.box.allocation') == 'default-bridge')


def available_bridge(networks):
    """Allocate through Docker, checking both Swarm pools and host routes."""
    label = 'aiursoft.box.allocation'
    owned = [n for n in networks if is_allocation(n)]
    blocked = [ipaddress.ip_network(p['Subnet']) for n in networks if n not in owned
               for p in (n['IPAM'].get('Config') or []) if ':' not in p['Subnet']]
    reserved = []
    try:
        for attempt in range(32):
            name = 'box-bridge-allocation' + (f'-{attempt}' if attempt else '')
            previous = next((n for n in networks if n['Name'] == name), None)
            if previous and (previous not in owned or previous['Driver'] != 'bridge' or previous.get('Containers')):
                raise RuntimeError('Bridge allocation name is already in use')
            reserve = previous['Id'] if previous else docker(
                'network', 'create', '--driver', 'bridge', '--label', f'{label}=default-bridge',
                '--opt', 'com.docker.network.bridge.inhibit_ipv4=true', name)
            reserved.append(reserve)
            allocation = inspect('network', reserve)[0]['IPAM']['Config'][0]
            pool = ipaddress.ip_network(allocation['Subnet'])
            temporary_devices = {f"br-{n['Id'][:12]}" for n in owned} | {f'br-{n[:12]}' for n in reserved}
            routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'table', 'all'))
            route_pools = [ipaddress.ip_network(r['dst'], strict=False) for r in routes
                           if r.get('dst', 'default') != 'default' and r.get('dev') not in temporary_devices]
            if not any(pool.overlaps(other) for other in blocked + route_pools):
                return f"{allocation['Gateway']}/{pool.prefixlen}"
            # Reserve rejected candidates until a compatible pool is selected.
        raise RuntimeError('Docker could not allocate a pool outside existing networks and routes')
    finally:
        for reserve in reversed(reserved):
            docker('network', 'rm', reserve)


def declarations():
    services = docker('service', 'ls', '-q').split()
    overlays = docker('network', 'ls', '-q', '--filter', 'driver=overlay').split()
    return {
        'services': sorted(({'ID': s['ID'], 'Spec': s['Spec']} for s in inspect('service', *services)),
                           key=lambda s: s['ID']) if services else [],
        'overlays': sorted(({'Id': n['Id'], 'IPAM': n['IPAM'], 'Options': n['Options']}
                            for n in inspect('network', *overlays)), key=lambda n: n['Id']) if overlays else [],
        'cluster': docker('info', '--format', '{{.Swarm.Cluster.ID}}'),
    }


def reconciled():
    rows = docker('service', 'ls', '--format', '{{.Replicas}}').splitlines()
    return all('/' in row and row.split('/')[0] == row.split('/')[1] for row in rows)



def initialize_swarm():
    routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
    device = routes[0]['dev']
    addresses = json.loads(run('ip', '-j', '-4', 'addr', 'show', 'dev', device))[0]['addr_info']
    address = next(a['local'] for a in addresses if a['scope'] == 'global')
    docker('swarm', 'init', '--advertise-addr', address)


def main():
    if PENDING.exists():
        restore(json.loads(PENDING.read_text()))
    info = json.loads(docker('info', '--format', '{{json .}}'))
    swarm = info['Swarm']
    active = swarm['LocalNodeState'] == 'active'
    if swarm['LocalNodeState'] not in ('active', 'inactive'):
        raise RuntimeError('Swarm is not ready for network reconciliation')
    if active and (not swarm['ControlAvailable'] or swarm['Nodes'] != 1):
        raise RuntimeError('Automatic network repair requires an independent single-node manager')
    config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    networks = inspect('network', *docker('network', 'ls', '-q').split())
    gw = next((n for n in networks if n['Name'] == 'docker_gwbridge'), None)
    bridge = next(n for n in networks if n['Name'] == 'bridge')
    pools = [(n['Name'], ipaddress.ip_network(p['Subnet'])) for n in networks
             for p in (n['IPAM'].get('Config') or []) if ':' not in p['Subnet'] and not is_allocation(n)]
    overlaps = [(a, b) for i, (a, x) in enumerate(pools) for b, y in pools[i + 1:] if x.overlaps(y)]
    if any('bridge' not in pair for pair in overlaps):
        raise RuntimeError('Unrelated network pools overlap; preserve existing business networks')
    repair_bridge = bool(overlaps)
    if active and gw and gw['EnableIPv6'] and config.get('userland-proxy') is False and not repair_bridge:
        print('Docker gateway already supports native IPv6; no changes or restarts.')
        return
    availability = inspect('node', swarm['NodeID'])[0]['Spec']['Availability'] if active else None
    if availability == 'pause':
        raise RuntimeError('Resume the paused node before network maintenance')
    if config.get('live-restore'):
        raise RuntimeError('Network repair requires Docker workloads to stop cleanly')
    if gw and (gw['Driver'] != 'bridge' or gw['IPAM']['Driver'] != 'default' or
               gw['Internal'] or gw['Attachable'] or gw['Ingress'] or
               any(p.get('AuxiliaryAddresses') for p in gw['IPAM']['Config'])):
        raise RuntimeError('Unsupported gateway configuration; no changes made')
    containers = docker('ps', '-q').split()
    for container in inspect('container', *containers) if containers else []:
        labels = container['Config'].get('Labels') or {}
        if not labels.get('com.docker.swarm.service.id'):
            if container['HostConfig']['RestartPolicy']['Name'] not in ('always', 'unless-stopped'):
                raise RuntimeError('Standalone workloads must have an automatic restart policy')
    if gw:
        for endpoint in gw.get('Containers', {}):
            if endpoint != 'ingress-sbox':
                container = inspect('container', endpoint)[0]
                if not (container['Config'].get('Labels') or {}).get('com.docker.swarm.service.id'):
                    raise RuntimeError('Gateway contains an unmanaged workload')
    candidate = dict(config, **{'userland-proxy': False})
    if repair_bridge:
        if bridge.get('Containers'):
            raise RuntimeError('Default bridge is in use; cannot renumber it safely')
        ids = docker('ps', '-aq').split()
        for container in inspect('container', *ids) if ids else []:
            if (not (container['Config'].get('Labels') or {}).get('com.docker.swarm.service.id') and
                    container['HostConfig']['NetworkMode'] in ('bridge', 'default')):
                raise RuntimeError('A container depends on the default bridge allocation')
        candidate['bip'] = available_bridge(networks)
    if not active and candidate == config and (not gw or gw['EnableIPv6']):
        if not gw:
            docker('network', 'create', *network_args(None), '--ipv6', 'docker_gwbridge')
        initialize_swarm()
        print('New Swarm initialized with a native IPv6 gateway; no Docker restart.')
        return
    before = declarations() if active else None
    if active:
        for service in inspect('service', *docker('service', 'ls', '-q').split()) if before['services'] else []:
            if service.get('UpdateStatus', {}).get('State', 'completed') not in ('completed', 'rollback_completed'):
                raise RuntimeError('A service update is in progress; retry after it finishes')
    # Validate before draining or touching the live daemon configuration.
    with tempfile.TemporaryDirectory(prefix='box-network-') as temp:
        validation = Path(temp) / 'daemon.json'
        save(validation, candidate)
        run('dockerd', '--validate', '--config-file', str(validation))
    node = swarm.get('NodeID') if active else None
    transaction = {
        'node': node,
        'availability': availability,
        'gateway': gw, 'config': config, 'rebuilding': False,
        'socket': subprocess.run(['systemctl', 'is-active', '--quiet', 'docker.socket']).returncode == 0,
    }
    backup = Path(tempfile.mkdtemp(prefix='backup-', dir=STATE))
    save(backup / 'declarations-before.json', before)
    save(backup / 'before.json', transaction)
    save(PENDING, transaction)
    try:
        if node:
            docker('node', 'update', '--availability', 'drain', node)
            wait_for(lambda: not docker('ps', '-q', '--filter', 'label=com.docker.swarm.service.id'),
                     'Swarm workloads did not stop')
        stop = ['systemctl', 'stop', 'docker.service']
        if transaction['socket']:
            stop.append('docker.socket')
        run(*stop)
        root = Path(info['DockerRootDir'])
        paths = [name for name in ('swarm', 'network') if (root / name).exists()]
        if paths:
            run('tar', '-C', str(root), '-czf', str(backup / 'docker-state.tgz'), *paths)
        if candidate != config:
            save(CONFIG, candidate)
        start_docker(transaction)
        if not gw or not gw['EnableIPv6']:
            transaction['rebuilding'] = True
            save(PENDING, transaction)
            detach_gateway()
            docker('network', 'create', *network_args(gw), '--ipv6', 'docker_gwbridge')
            if active:
                run('systemctl', 'restart', 'docker.service')
                start_docker(transaction)
        if node:
            if docker('info', '--format', '{{.Swarm.NodeID}}') != node:
                raise RuntimeError('Swarm node identity changed')
            docker('node', 'update', '--availability', transaction['availability'], node)
            if transaction['availability'] == 'active':
                wait_for(reconciled, 'Swarm service replicas did not recover', seconds=600)
            after = declarations()
            save(backup / 'declarations-after.json', after)
            if after['cluster'] != before['cluster']:
                raise RuntimeError('Swarm cluster identity changed')
            if after != before:
                # A concurrent normal deployment or Shepherd update must not be undone.
                print(f'Concurrent declaration changes observed; snapshots retained in {backup}.', flush=True)
        else:
            initialize_swarm()
        if not gateway()['EnableIPv6']:
            raise RuntimeError('Native IPv6 gateway verification failed')
        PENDING.unlink()
        print(f'Native IPv6 gateway ready. Previous metadata retained in {backup}.')
    except BaseException:
        restore(transaction)
        raise


if __name__ == '__main__':
    if os.geteuid() != 0:
        sys.exit('Run this host operation through sudo.')
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        def interrupted(signum, frame):
            raise RuntimeError(f'Network reconciliation interrupted by signal {signum}')
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        try:
            main()
        except (RuntimeError, subprocess.SubprocessError) as error:
            print(f'Network reconciliation failed: {error}', file=sys.stderr)
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                print(error.stderr.strip(), file=sys.stderr)
            if PENDING.exists():
                print('Recovery state retained; the next deployment will resume recovery.', file=sys.stderr)
            sys.exit(1)
