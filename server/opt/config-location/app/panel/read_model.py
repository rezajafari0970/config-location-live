from __future__ import annotations
from collections import Counter
from pathlib import Path
from typing import Any
import json
from app.country.panel_projection_adapter import overlay_country_collection
STATE_ROOT = Path('/var/lib/config-location')
CONFIG_ROOT = STATE_ROOT / 'configs'
HEALTH_ROOT = STATE_ROOT / 'health-results' / 'latest'
LIFECYCLE_ROOT = STATE_ROOT / 'health-lifecycle'
COUNTRY_ROOT = STATE_ROOT / 'country'
IDENTITY_ROOT = COUNTRY_ROOT / 'country-identity'
PIPELINE_ROOT = COUNTRY_ROOT / 'pipeline' / 'latest'
UNCERTAIN_STATES = {'ambiguous', 'unknown', 'unresolved'}

def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, ValueError, TypeError):
        return None
    if not isinstance(value, dict):
        return None
    return value

def _first_existing(root: Path, config_id: str) -> dict[str, Any] | None:
    path = root / f'{config_id}.json'
    if not path.exists():
        return None
    return _read_json(path)

def _config_id_from_record(record: dict[str, Any], fallback: str) -> str:
    return str(record.get('config_id') or record.get('id') or fallback)

def iter_config_records():
    if not CONFIG_ROOT.exists():
        return
    for path in sorted(CONFIG_ROOT.glob('*.json')):
        record = _read_json(path)
        if record is None:
            continue
        cid = _config_id_from_record(record, path.stem)
        yield (cid, record)

def _country_view(*, identity: dict[str, Any] | None, pipeline: dict[str, Any] | None) -> dict[str, Any]:
    identity = identity or {}
    pipeline = pipeline or {}
    locked = identity.get('locked') is True and bool(identity.get('country_code'))
    if locked:
        code = str(identity.get('country_code')).upper()
        name = identity.get('country_name') or pipeline.get('country_name')
        source = 'identity'
    else:
        code = str(pipeline.get('country_code')).upper() if pipeline.get('country_code') else None
        name = pipeline.get('country_name')
        source = 'pipeline' if code else None
    state = str(pipeline.get('state') or 'unknown')
    unresolved = not bool(code) or state.lower() in UNCERTAIN_STATES
    return overlay_country_collection({'country_code': code, 'country_name': name, 'country_locked': locked, 'country_source': source, 'country_state': state, 'country_unresolved': unresolved, 'exit_ip': pipeline.get('exit_ip'), 'country_confidence': pipeline.get('confidence'), 'rotating': state.lower() in {'confirmed_rotating', 'confirmed_rotating_ip'}})

def build_config_view(config_id: str, config: dict[str, Any]) -> dict[str, Any]:
    health = _first_existing(HEALTH_ROOT, config_id)
    lifecycle = _first_existing(LIFECYCLE_ROOT, config_id)
    identity = _first_existing(IDENTITY_ROOT, config_id)
    pipeline = _first_existing(PIPELINE_ROOT, config_id)
    country = _country_view(identity=identity, pipeline=pipeline)
    source_ids = config.get('source_ids') or []
    if not isinstance(source_ids, list):
        source_ids = []
    health_status = (health or {}).get('state') or (health or {}).get('status') or (health or {}).get('health_status') or 'unknown'
    lifecycle_state = (lifecycle or {}).get('state') or (lifecycle or {}).get('status') or 'unknown'
    return overlay_country_collection({'config_id': config_id, 'config_type': config.get('config_type') or config.get('type') or 'unknown', 'last_seen': config.get('last_seen_at') or config.get('last_seen'), 'first_seen': config.get('first_seen_at') or config.get('first_seen'), 'source_count': len(source_ids), 'source_ids': source_ids, 'health_status': str(health_status), 'lifecycle_state': str(lifecycle_state), **country})

def iter_config_views():
    for cid, config in iter_config_records():
        yield build_config_view(cid, config)

def dashboard_summary() -> dict[str, Any]:
    total = 0
    types = Counter()
    health = Counter()
    lifecycle = Counter()
    countries = Counter()
    country_states = Counter()
    country_known = 0
    unresolved = 0
    rotating = 0
    for row in iter_config_views():
        total += 1
        types[row['config_type']] += 1
        health[row['health_status']] += 1
        lifecycle[row['lifecycle_state']] += 1
        country_states[row['country_state']] += 1
        if row['country_code']:
            country_known += 1
            countries[row['country_code']] += 1
        if row['country_unresolved']:
            unresolved += 1
        if row['rotating']:
            rotating += 1
    return {'total_configs': total, 'country_known': country_known, 'country_unresolved': unresolved, 'country_rotating': rotating, 'country_coverage_percent': round(country_known / total * 100.0 if total else 0.0, 2), 'types': dict(types), 'health': dict(health), 'lifecycle': dict(lifecycle), 'country_states': dict(country_states), 'countries': dict(countries.most_common())}

def query_configs(*, search: str='', config_type: str='', health_status: str='', country_code: str='', country_state: str='', unresolved_only: bool=False, offset: int=0, limit: int=100) -> dict[str, Any]:
    search = search.strip().lower()
    config_type = config_type.strip().lower()
    health_status = health_status.strip().lower()
    country_code = country_code.strip().upper()
    country_state = country_state.strip().lower()
    offset = max(0, int(offset))
    limit = max(1, min(int(limit), 500))
    matched = []
    for row in iter_config_views():
        if config_type and str(row['config_type']).lower() != config_type:
            continue
        if health_status and str(row['health_status']).lower() != health_status:
            continue
        if country_code and str(row['country_code'] or '').upper() != country_code:
            continue
        if country_state and str(row['country_state']).lower() != country_state:
            continue
        if unresolved_only and (not row['country_unresolved']):
            continue
        if search:
            haystack = ' '.join([str(row.get('config_id', '')), str(row.get('config_type', '')), str(row.get('country_code', '')), str(row.get('country_name', '')), str(row.get('exit_ip', ''))]).lower()
            if search not in haystack:
                continue
        matched.append(row)
    total = len(matched)
    page = matched[offset:offset + limit]
    return overlay_country_collection({'total': total, 'offset': offset, 'limit': limit, 'items': page})
RESULTS_ROOT = COUNTRY_ROOT / 'results' / 'latest'

def _config_record_by_id(config_id: str) -> dict[str, Any] | None:
    direct = CONFIG_ROOT / f'{config_id}.json'
    if direct.exists():
        value = _read_json(direct)
        if value is not None:
            return overlay_country_collection(value)
    for cid, record in iter_config_records():
        if cid == config_id:
            return overlay_country_collection(record)
    return overlay_country_collection(None)

def config_detail(config_id: str) -> dict[str, Any] | None:
    config_id = str(config_id or '').strip()
    if not config_id:
        return overlay_country_collection(None)
    config = _config_record_by_id(config_id)
    if config is None:
        return overlay_country_collection(None)
    health = _first_existing(HEALTH_ROOT, config_id)
    lifecycle = _first_existing(LIFECYCLE_ROOT, config_id)
    identity = _first_existing(IDENTITY_ROOT, config_id)
    pipeline = _first_existing(PIPELINE_ROOT, config_id)
    result = _first_existing(RESULTS_ROOT, config_id)
    summary = build_config_view(config_id, config)
    raw = config.get('raw') or config.get('source') or config.get('config')
    return overlay_country_collection({'config_id': config_id, 'summary': summary, 'config': {'config_type': config.get('config_type') or config.get('type'), 'first_seen_at': config.get('first_seen_at') or config.get('first_seen'), 'last_seen_at': config.get('last_seen_at') or config.get('last_seen'), 'source_ids': config.get('source_ids') or [], 'raw': raw}, 'health': health, 'lifecycle': lifecycle, 'country_identity': identity, 'country_pipeline': pipeline, 'country_result': result})
