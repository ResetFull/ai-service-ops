"""Synthetic output only. This executable never imports an SSH client."""
import sys

action = sys.argv[3] if len(sys.argv) > 3 else "health"
print("SAMPLE time=2026-01-01T12:00:00+0000 timezone=UTC host=offline-fixture simulated=true")
if action == "status":
    print("RESULT NO_MATCH observation=process simulated=true")
elif action in {"net", "jvm"}:
    print("RESULT NO_MATCH simulated=true")
else:
    print("2026-01-01 12:00:00 ERROR BindException: demo port already in use")
    print("password=demo-secret phone=13812345678")
    print('TASK_EVENT {"phase":"install","status":"completed","release_id":"20260101120000-abcdef12"}')
    print("RESULT OK files=1 bytes=240 simulated=true")
