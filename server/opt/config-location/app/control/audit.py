from __future__ import annotations
import json,os,time
from datetime import datetime,timezone
from pathlib import Path
from filelock import FileLock
LOG_DIR=Path("/var/log/config-location/control"); LOCK=Path("/run/config-location/control-audit.lock")
def audit(action,result,detail="",*,actor="control-plane"):
    LOG_DIR.mkdir(parents=True,exist_ok=True); LOCK.parent.mkdir(parents=True,exist_ok=True)
    p=LOG_DIR/(datetime.now(timezone.utc).strftime("%Y-%m-%d")+".jsonl")
    rec={"timestamp":datetime.now(timezone.utc).isoformat(),"epoch":time.time(),"action":str(action),"result":str(result),"actor":str(actor),"detail":str(detail)[:4000]}
    with FileLock(str(LOCK),timeout=10):
        with p.open("a",encoding="utf-8") as f:
            f.write(json.dumps(rec,ensure_ascii=False,separators=(",",":"))+"\n"); f.flush(); os.fsync(f.fileno())
        fd=os.open(str(LOG_DIR),os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    return rec
