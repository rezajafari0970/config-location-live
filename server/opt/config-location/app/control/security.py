from __future__ import annotations
import hmac,json
from pathlib import Path
POLICY=Path("/etc/config-location/control-policy.json"); TOKEN=Path("/etc/config-location/control-token")
DEFAULT_ALLOWED_ACTIONS={"status","resources"}
class ControlSecurityError(RuntimeError): pass
def get_policy():
    if not POLICY.exists(): return {"allowed_actions":sorted(DEFAULT_ALLOWED_ACTIONS)}
    try: obj=json.loads(POLICY.read_text(encoding="utf-8"))
    except Exception as e: raise ControlSecurityError("control_policy_corrupt") from e
    if not isinstance(obj,dict): raise ControlSecurityError("control_policy_not_object")
    a=obj.get("allowed_actions")
    if not isinstance(a,list): raise ControlSecurityError("control_policy_allowed_actions_invalid")
    out=[]
    for x in a:
        if not isinstance(x,str) or not x.strip(): raise ControlSecurityError("control_policy_action_invalid")
        out.append(x.strip())
    obj=dict(obj); obj["allowed_actions"]=sorted(set(out)); return obj
def check_action(action):
    if not isinstance(action,str) or not action.strip(): return False
    try: return action.strip() in get_policy().get("allowed_actions",[])
    except ControlSecurityError: return False
def _read_token():
    if not TOKEN.exists(): return None
    try:
        st=TOKEN.stat()
        if st.st_mode & 0o022: return None
        v=TOKEN.read_text(encoding="utf-8").strip()
    except OSError: return None
    return v or None
def check_token(value):
    if not isinstance(value,str): return False
    e=_read_token(); return e is not None and hmac.compare_digest(value.strip(),e)
def security_status():
    try: p=get_policy(); valid=True; err=None
    except ControlSecurityError as e: p={"allowed_actions":[]}; valid=False; err=str(e)
    return {"token_configured":_read_token() is not None,"policy_valid":valid,"policy_error":err,"allowed_actions":list(p.get("allowed_actions",[]))}
