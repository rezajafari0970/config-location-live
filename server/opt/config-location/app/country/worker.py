from __future__ import annotations
import fcntl
import json
import os
import tempfile
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from .pipeline import process_country
CONFIG_ROOT = Path('/var/lib/config-location/configs')
HEALTH_ROOT = Path('/var/lib/config-location/health-results/latest')
COUNTRY_ROOT = Path('/var/lib/config-location/country/pipeline/latest')
WORKER_ROOT = Path('/var/lib/config-location/country/worker')
STATE_PATH = WORKER_ROOT / 'state.json'
REPORT_PATH = WORKER_ROOT / 'last-run.json'
LOCK_PATH = Path('/run/config-location-country-worker.lock')
RETRY_SECONDS = {'missing': 0, 'pending_confirmation': 2 * 60, 'unknown': 3 * 60, 'ambiguous': 3 * 60, 'unstable_exit': 3 * 60, 'error': 5 * 60, 'rotating': 5 * 60, 'confirmed_stable': None, 'confirmed_rotating_ip': None, 'confirmed': None}

def now_epoch() -> int:
    return int(time.time())

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()

def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix='.' + path.name + '.', suffix='.tmp')
    _CONFIGLOC_PIPELINE_GID = __import__('grp').getgrnam('configloc').gr_gid
    os.fchown(fd, -1, _CONFIGLOC_PIPELINE_GID)
    os.fchmod(fd, 416)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

class CountryWorkerLock:

    def __init__(self, path: Path=LOCK_PATH):
        self.path = path
        self.fd = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = open(self.path, 'a+')
        try:
            fcntl.flock(self.fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.fd.close()
            self.fd = None
            raise RuntimeError('country_worker_already_running')
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd.fileno(), fcntl.LOCK_UN)
            finally:
                self.fd.close()

def load_json(path: Path) -> dict[str, Any] | None:
    try:
        o = json.loads(path.read_text())
    except Exception:
        return None
    return o if isinstance(o, dict) else None

def load_worker_state() -> dict[str, Any]:
    o = load_json(STATE_PATH)
    if not o:
        return {'schema_version': 1, 'records': {}}
    records = o.get('records')
    if not isinstance(records, dict):
        records = {}
    return {'schema_version': 1, 'records': records}

def country_state(config_id: str) -> str:
    p = COUNTRY_ROOT / f'{config_id}.json'
    o = load_json(p)
    if not o:
        return 'missing'
    return str(o.get('state', 'unknown')).strip().lower()

def healthy_candidates() -> list[tuple[int, str, dict, dict]]:
    now = now_epoch()
    state = load_worker_state()
    worker_records = state['records']
    result = []
    for hp in HEALTH_ROOT.glob('*.json'):
        health = load_json(hp)
        if not health:
            continue
        if str(health.get('state', '')).lower() != 'healthy':
            continue
        config_id = hp.stem
        cp = CONFIG_ROOT / f'{config_id}.json'
        record = load_json(cp)
        if not record:
            continue
        cstate = country_state(config_id)
        previous = worker_records.get(config_id, {})
        last_run = int(previous.get('last_run_epoch', 0) or 0)
        retry = RETRY_SECONDS.get(cstate, 3 * 60)
        if retry is None:
            continue
        due = last_run + retry
        if now < due:
            continue
        priority = {'missing': 0, 'unknown': 1, 'ambiguous': 1, 'unstable_exit': 1, 'error': 2, 'pending_confirmation': 3, 'rotating': 4}.get(cstate, 3)
        result.append((priority, config_id, record, health))
    result.sort(key=lambda x: (x[0], x[1]))
    return result

def run_country_worker_once(*, max_jobs: int=10) -> dict[str, Any]:
    WORKER_ROOT.mkdir(parents=True, exist_ok=True)
    with CountryWorkerLock():
        started = utc_now()
        worker_state = load_worker_state()
        records = worker_state['records']
        candidates = healthy_candidates()
        selected = candidates[:max_jobs]
        stats = Counter()
        processed = []
        for priority, config_id, record, health in selected:
            before = country_state(config_id)
            try:
                result = process_country(config_id=config_id, record=record, health=health)
            except Exception as e:
                result = {'config_id': config_id, 'state': 'error', 'reason': 'worker_pipeline_exception', 'error': str(e)[:1000]}
            final_state = str(result.get('state', 'error'))
            stats[final_state] += 1
            records[config_id] = {'last_run_at': utc_now(), 'last_run_epoch': now_epoch(), 'previous_country_state': before, 'result_state': final_state, 'country_code': result.get('country_code'), 'exit_ip': result.get('exit_ip')}
            processed.append({'config_id': config_id, 'priority': priority, 'previous_state': before, 'result_state': final_state, 'country_code': result.get('country_code'), 'exit_ip': result.get('exit_ip'), 'reason': result.get('reason'), 'error': result.get('error')})
        current_ids = {p.stem for p in CONFIG_ROOT.glob('*.json')}
        stale = [config_id for config_id in records if config_id not in current_ids]
        for config_id in stale:
            records.pop(config_id, None)
        worker_state['updated_at'] = utc_now()
        worker_state['records'] = records
        worker_state['gc_removed'] = len(stale)
        atomic_json(STATE_PATH, worker_state)
        report = {'schema_version': 1, 'mode': 'shadow', 'started_at': started, 'finished_at': utc_now(), 'eligible_due': len(candidates), 'selected': len(selected), 'processed': len(processed), 'states': dict(stats), 'gc_removed': len(stale), 'jobs': processed}
        atomic_json(REPORT_PATH, report)
        return report

def run_country_worker_adaptive(*, max_jobs: int, concurrency: int):
    """
    Adaptive parallel Country batch.

    Selection and global ownership remain protected by
    the Country Worker lock.

    Each config owns an independent Xray sandbox.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed
    concurrency = max(1, min(int(concurrency), 8))
    max_jobs = max(1, min(int(max_jobs), 24))
    WORKER_ROOT.mkdir(parents=True, exist_ok=True)
    with CountryWorkerLock():
        started = utc_now()
        worker_state = load_worker_state()
        records = worker_state['records']
        candidates = healthy_candidates()
        selected = candidates[:max_jobs]

        def execute(item):
            priority, config_id, record, health = item
            before = country_state(config_id)
            try:
                result = process_country(config_id=config_id, record=record, health=health)
            except Exception as e:
                result = {'config_id': config_id, 'state': 'error', 'reason': 'adaptive_worker_exception', 'error': str(e)[:1000]}
            return (priority, config_id, before, result)
        completed = []
        with ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix='country') as pool:
            futures = [pool.submit(execute, item) for item in selected]
            for future in as_completed(futures):
                completed.append(future.result())
        stats = Counter()
        processed = []
        for priority, config_id, before, result in completed:
            final_state = str(result.get('state', 'error'))
            stats[final_state] += 1
            records[config_id] = {'last_run_at': utc_now(), 'last_run_epoch': now_epoch(), 'previous_country_state': before, 'result_state': final_state, 'country_code': result.get('country_code'), 'exit_ip': result.get('exit_ip')}
            processed.append({'config_id': config_id, 'priority': priority, 'previous_state': before, 'result_state': final_state, 'country_code': result.get('country_code'), 'exit_ip': result.get('exit_ip'), 'reason': result.get('reason'), 'error': result.get('error')})
        current_ids = {p.stem for p in CONFIG_ROOT.glob('*.json')}
        stale = [cid for cid in records if cid not in current_ids]
        for cid in stale:
            records.pop(cid, None)
        worker_state['updated_at'] = utc_now()
        worker_state['records'] = records
        worker_state['gc_removed'] = len(stale)
        atomic_json(STATE_PATH, worker_state)
        report = {'schema_version': 2, 'mode': 'adaptive', 'started_at': started, 'finished_at': utc_now(), 'eligible_due': len(candidates), 'selected': len(selected), 'processed': len(processed), 'concurrency': concurrency, 'states': dict(stats), 'gc_removed': len(stale), 'jobs': processed}
        atomic_json(REPORT_PATH, report)
        return report
