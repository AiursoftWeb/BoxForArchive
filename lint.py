#!/usr/bin/env python3
import os
from decimal import Decimal
import re
import sys
import yaml


# ---------------------------------------------------------------------------
# FRP ↔ docker-compose port consistency helpers
# ---------------------------------------------------------------------------

def _load_compose_yaml(path: str) -> dict | None:
    """
    Load a docker-compose YAML file, tolerating template placeholders such as
    ---DOMAINS--- (YAML document-start markers) and {{VAR}} expressions.
    Returns the parsed dict, or None on unrecoverable parse error.
    """
    with open(path) as f:
        content = f.read()
    # Replace ---PLACEHOLDER--- lines with an empty YAML list so the
    # document is still valid when template vars haven't been substituted.
    content = re.sub(r'^---[A-Z0-9_]+-+.*$', '[]', content, flags=re.MULTILINE)
    # Replace {{VAR}} with a plain string so YAML doesn't choke.
    content = re.sub(r'\{\{[^}]+\}\}', 'PLACEHOLDER', content)
    try:
        return yaml.safe_load(content) or {}
    except yaml.YAMLError:
        return None


def _parse_frpc_toml(path: str) -> list[dict]:
    """
    Parse frpc.toml line-by-line and return a list of [[proxies]] entries.
    Each entry is a dict with keys: name, type, localIP, localPort, remotePort
    (only the keys that are present in the file).
    """
    proxies: list[dict] = []
    current: dict = {}
    in_proxy = False

    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if line == '[[proxies]]':
                if in_proxy and current:
                    proxies.append(current)
                current = {}
                in_proxy = True
                continue
            if not in_proxy:
                continue
            if line.startswith('[') or not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            key, _, val = line.partition('=')
            key = key.strip()
            val = val.strip().strip('"')
            if key in ('name', 'type', 'localIP'):
                current[key] = val
            elif key in ('localPort', 'remotePort'):
                try:
                    current[key] = int(val)
                except ValueError:
                    pass

    if in_proxy and current:
        proxies.append(current)
    return proxies


def _collect_host_ports(base_dir: str) -> list[tuple[str, int, str, str]]:
    """
    Walk *all* stages under base_dir and collect every port entry that has
    mode: host AND belongs to a service connected to frp_net.

    Returns a list of (swarm_dns_name, container_port, protocol, file_path).
    swarm_dns_name = '<stack>_<service>' (Docker Swarm DNS convention).
    """
    results: list[tuple[str, int, str, str]] = []
    compose_names = ('docker-compose.yml', 'docker-compose.template.yml',
                     'docker.compose.yml')

    for dirpath, _dirs, filenames in os.walk(base_dir):
        for fn in filenames:
            if fn not in compose_names:
                continue
            path = os.path.join(dirpath, fn)
            data = _load_compose_yaml(path)
            if data is None:
                continue
            services = data.get('services') or {}
            stack_name = os.path.basename(dirpath)

            for svc_name, svc_conf in services.items():
                if not svc_conf:
                    continue

                # Only services connected to frp_net are reachable by FRP.
                networks = svc_conf.get('networks') or {}
                if isinstance(networks, list):
                    on_frp_net = 'frp_net' in networks
                else:
                    on_frp_net = 'frp_net' in networks
                if not on_frp_net:
                    continue

                swarm_name = f"{stack_name}_{svc_name}"
                for port_entry in svc_conf.get('ports') or []:
                    if not isinstance(port_entry, dict):
                        continue
                    if port_entry.get('mode') != 'host':
                        continue
                    target = port_entry.get('target')
                    if target is None:
                        continue
                    proto = port_entry.get('protocol', 'tcp')
                    results.append((swarm_name, int(target), proto, path))

    return results


def check_frp_consistency(base_dir: str) -> bool:
    """
    Cross-check frpc.toml proxies against docker-compose host-mode ports:

    1. Every host-mode port on a frp_net service must have an FRP proxy.
    2. Every FRP proxy (localIP/localPort/type) must map to a real service port.

    Returns True when everything is consistent.
    """
    frpc_path = os.path.join(base_dir, 'stage2', 'images', 'frp', 'frpc.toml')
    if not os.path.exists(frpc_path):
        # No FRP configuration for this box – nothing to check.
        return True

    print(f"\n→ FRP 端口一致性检查 (配置: {frpc_path})")

    proxies = _parse_frpc_toml(frpc_path)
    # Index: (localIP, localPort, type) → proxy dict
    frp_index: dict[tuple[str, int, str], dict] = {}
    for p in proxies:
        if 'localIP' in p and 'localPort' in p and 'type' in p:
            frp_index[(p['localIP'], p['localPort'], p['type'])] = p

    host_ports = _collect_host_ports(base_dir)
    # Index: (swarm_name, port, protocol) → file path
    host_index: dict[tuple[str, int, str], str] = {}
    for swarm_name, port, proto, fpath in host_ports:
        host_index[(swarm_name, port, proto)] = fpath

    all_ok = True

    # Rule 1: every internal host-mode port must have an FRP proxy entry.
    for (swarm_name, port, proto), fpath in sorted(host_index.items()):
        if (swarm_name, port, proto) not in frp_index:
            print(f"  ❌ {fpath}")
            print(f"     服务 '{swarm_name}' 在内部以 mode:host 暴露了端口 {port}/{proto}，"
                  f"但 frpc.toml 中没有对应的代理条目")
            all_ok = False

    # Rule 2: every FRP proxy must have a matching internal host-mode port.
    for (local_ip, local_port, ptype), proxy in sorted(frp_index.items()):
        if (local_ip, local_port, ptype) not in host_index:
            print(f"  ❌ frpc.toml (proxy '{proxy.get('name', '?')}')")
            print(f"     FRP 代理要求 {local_ip}:{local_port}/{ptype}，"
                  f"但没有找到任何服务以 mode:host 暴露该端口")
            all_ok = False

    if all_ok:
        print("  ✅ FRP 端口一致性检查通过")
    return all_ok


def parse_duration_seconds(value) -> float | None:
    """
    解析 docker compose duration 字符串，返回秒数。
    支持常见单位：h、m、s、ms、us、ns。
    """
    if not isinstance(value, str):
        return None

    text = value.strip()
    if not text:
        return None

    if text in ('0', '+0'):
        return 0.0
    if text.startswith('+'):
        text = text[1:]

    matches = re.findall(r'(\d+(?:\.\d*)?|\.\d+)(h|ms|us|µs|μs|ns|m|s)', text)
    if not matches:
        return None

    rebuilt = ''.join(f'{number}{unit}' for number, unit in matches)
    if rebuilt != text:
        return None

    # Docker durations use signed 64-bit nanoseconds, including fractional units.
    total_nanoseconds = 0
    unit_scale = {
        'h': 3_600_000_000_000,
        'm': 60_000_000_000,
        's': 1_000_000_000,
        'ms': 1_000_000,
        'us': 1_000,
        'µs': 1_000,
        'μs': 1_000,
        'ns': 1,
    }

    for number, unit in matches:
        total_nanoseconds += int(Decimal(number) * unit_scale[unit])
        if total_nanoseconds > (1 << 63) - 1:
            return None

    return total_nanoseconds / 1_000_000_000


def is_stateless(conf: dict) -> bool:
    """
    判断服务是否为无状态：
    - stop_grace_period 为 20s
    - 或 deploy.replicas > 2
    - 或 deploy.update_config.order 为 start-first
    """
    sgp = conf.get('stop_grace_period')
    if isinstance(sgp, str) and sgp.endswith('s') and sgp[:-1] == '20':
        return True
    replicas = conf.get('deploy', {}) .get('replicas')
    if isinstance(replicas, int) and replicas > 2:
        return True
    order = conf.get('deploy', {}).get('update_config', {}).get('order')
    if order == 'start-first':
        return True
    return False


def validate_service(name: str, conf: dict):
    """
    根据服务类型（无状态/有状态）校验必需字段及取值规范，
    返回 (is_stateless, error_list)
    """
    errors = []
    stateless = is_stateless(conf)
    upd = conf.get('deploy', {}).get('update_config', {})

    # Omitted delays use Docker's default. Explicit values must be durations.
    if 'delay' in upd:
        delay = upd['delay']
        seconds = parse_duration_seconds(delay)
        if seconds is None or delay != delay.strip():
            errors.append('deploy.update_config.delay must be a nonnegative duration')

    if stateless:
        # 无状态服务规范
        if conf.get('stop_grace_period') != '20s':
            errors.append("stop_grace_period 应为 '20s'")
        if upd.get('order') != 'start-first':
            errors.append("deploy.update_config.order 应为 'start-first'")
    else:
        # 有状态服务规范
        stop_grace_period = parse_duration_seconds(conf.get('stop_grace_period'))
        if stop_grace_period is None or stop_grace_period < 60:
            errors.append("stop_grace_period 应大于等于 '60s'")
        if upd.get('order') != 'stop-first':
            errors.append("deploy.update_config.order 应为 'stop-first'")
        replicas = conf.get('deploy', {}).get('replicas')
        if replicas not in (None, 1):
            errors.append("deploy.replicas 应不存在或等于 1")

    return stateless, errors


def process_file(path: str):
    print(f"\n→ 检查文件: {path}")
    data = _load_compose_yaml(path) or {}
    services = data.get('services')
    if not isinstance(services, dict):
        print("  ⚠️ 未发现 services 节点或格式不正确，跳过")
        return

    has_error = False
    for svc_name, svc_conf in services.items():
        stateless, errs = validate_service(svc_name, svc_conf or {})
        svc_type = '无状态' if stateless else '有状态'
        print(f"  服务 '{svc_name}' 被检测为 {svc_type}")
        if errs:
            has_error = True
            print("    ❌ 配置不符合规范：")
            for e in errs:
                print(f"      - {e}")

def main(root='./stage4'):
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            if fn in ('docker-compose.yml', 'docker.compose.yml'):
                process_file(os.path.join(dirpath, fn))

    # FRP ↔ docker-compose port consistency (scans all stages)
    base_dir = os.path.normpath(os.path.join(root, '..'))
    check_frp_consistency(base_dir)


if __name__ == '__main__':
    root_dir = sys.argv[1] if len(sys.argv) > 1 else './stage4'
    main(root_dir)
