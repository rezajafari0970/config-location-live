from __future__ import annotations
import json
import os
import time
from pathlib import Path

def _recover_corrupt_identity(p):
    try:
        if not path.exists():
            return False
        import json
        value = json.loads(path.read_text(encoding='utf-8', errors='strict'))
        if isinstance(value, dict):
            return False
    except Exception:
        pass
    try:
        path.unlink()
        return True
    except OSError:
        return False
ROOT = Path('/var/lib/config-location/country/country-identity')

def _path(config_id: str) -> Path:
    return ROOT / f'{config_id}.json'

def load_identity(config_id: str) -> dict | None:
    p = _path(config_id)
    if not p.exists():
        return None
    try:
        o = json.loads(p.read_text())
    except Exception:
        _recover_corrupt_identity(p)
        return None
    if not isinstance(o, dict):
        return None
    if not o.get('country_code'):
        return None
    if not o.get('locked'):
        return None
    return o

def save_identity_once(*, config_id: str, geo: dict, exit_ip: str) -> dict | None:
    """
    Persist Country only after a usable Geo result.

    Once persisted, this identity is immutable during
    normal Health cycles. Ambiguous/unresolved configs
    are deliberately NOT locked and remain eligible
    for later K7 recovery.
    """
    existing = load_identity(config_id)
    if existing is not None:
        return existing
    code = geo.get('country_code')
    state = str(geo.get('state') or '')
    if not code:
        return None
    if state not in {'confirmed', 'confirmed_stable', 'confirmed_rotating_ip'}:
        return None
    value = {'schema_version': 1, 'config_id': config_id, 'locked': True, 'country_code': str(code).upper(), 'country_name': geo.get('country_name'), 'flag': geo.get('flag'), 'asn': geo.get('asn'), 'network_name': geo.get('network_name'), 'network_type': geo.get('network_type'), 'country_confidence': geo.get('country_confidence'), 'first_exit_ip': str(exit_ip), 'geo_state': state, 'determined_epoch': int(time.time()), 'source': 'k6c-country-once'}
    ROOT.mkdir(parents=True, exist_ok=True)
    p = _path(config_id)
    try:
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 384)
        _CONFIGLOC_IDENTITY_GID = __import__('grp').getgrnam('configloc').gr_gid
        os.fchown(fd, -1, _CONFIGLOC_IDENTITY_GID)
        os.fchmod(fd, 416)
    except FileExistsError:
        return load_identity(config_id)
    try:
        os.write(fd, json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    return value

def identity_to_geo(identity: dict) -> dict:
    """
    Shape compatible with the fields consumed by the
    Event Consumer without invoking Geo providers.
    """
    return {'state': 'confirmed', 'country_code': identity.get('country_code'), 'country_name': identity.get('country_name'), 'flag': identity.get('flag'), 'asn': identity.get('asn'), 'network_name': identity.get('network_name'), 'network_type': identity.get('network_type'), 'country_confidence': identity.get('country_confidence'), 'cache_hit': True, 'singleflight_role': 'config_country_identity', 'country_identity_hit': True}
