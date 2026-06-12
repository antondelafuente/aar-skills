#!/usr/bin/env python3
"""gpu-job: deploy a disposable GPU pod (RunPod backend) and wait for direct SSH.

Config: ~/.config/gpu-job/env (KEY=VAL lines, written by gpu_job_init.sh); process env
overrides. Required: RUNPOD_API_KEY (or API_KEY_ENV=<var name> to read another), SSH_PUBLIC_KEY. Knobs (env): GPU_TYPE (default
"NVIDIA H200"), GPU_COUNT (1), DISK_GB (220), POD_NAME ("gpu-job"), IMAGE, TEMPLATE_ID,
DATA_CENTERS (comma list, or "all" = every known DC; overrides tiered retry), VOLUME_ID
(network volume; requires DATA_CENTERS), RETRY_MINUTES (keep retrying ~3-min cycles until
stock appears or the deadline passes — scarce multi-GPU stock can take an hour; default 0 =
single pass), PASS_ENV (comma list of extra var names to inject into the pod's env).
If RCLONE_CONF_B64 is set (by init, from your rclone.conf remote), it is injected so the
pod can read/write your artifact store.

Prints POD_ID / SSH / COST_PER_HR. Tiered US-west→central→east→EU region retry.
Battle-tested lineage: extracted from a research lab's deploy after three independent
hand-rolled variants in one day; the 220GB default exists because 30GB kills any pod
that downloads a large base model.
"""
import json, os, time, urllib.request, urllib.error

CFG = os.path.expanduser("~/.config/gpu-job/env")


def env(key, default=None, required=False):
    v = os.environ.get(key)
    if v:
        return v
    try:
        for line in open(CFG):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    if required and default is None:
        raise SystemExit(f"missing {key} (set it in {CFG} via gpu_job_init.sh, or in env)")
    return default


# API_KEY_ENV names the variable holding the key (default RUNPOD_API_KEY). The indirection
# exists for multi-account instances: a sourced .env exporting RUNPOD_API_KEY would otherwise
# silently override the config and deploy to the wrong account (real incident: a research pod
# billed to a personal account, and teardown-by-the-other-key 404'd, masquerading as deleted).
KEY_NAME = env("API_KEY_ENV", default="RUNPOD_API_KEY")
KEY = env(KEY_NAME, required=True)
PUBLIC_KEY = env("SSH_PUBLIC_KEY", required=True)
TIERS = [["US-CA-2", "US-WA-1"],
         ["US-TX-1", "US-TX-3", "US-TX-4", "US-KS-2", "US-KS-3", "US-IL-1"],
         ["US-GA-1", "US-GA-2", "US-NC-1", "US-DE-1"],
         ["EU-RO-1", "EUR-IS-1", "EU-CZ-1", "EU-NL-1", "EU-FR-1"]]


def post_rest(path, body):
    req = urllib.request.Request("https://rest.runpod.io/v1" + path,
                                 data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400]


def gql(query):
    req = urllib.request.Request(f"https://api.runpod.io/graphql?api_key={KEY}",
                                 data=json.dumps({"query": query}).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "curl/8.5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def pod_env():
    e = {"PUBLIC_KEY": PUBLIC_KEY}
    if env("RCLONE_CONF_B64"):
        e["RCLONE_CONF_B64"] = env("RCLONE_CONF_B64")
    if env("RCLONE_REMOTE") and env("RCLONE_REMOTE") != "skip":
        e["RCLONE_REMOTE"] = env("RCLONE_REMOTE")
    for var in (env("PASS_ENV", "") or "").split(","):
        var = var.strip()
        if var and env(var):
            e[var] = env(var)
    return e


def deploy():
    base = {"computeType": "GPU",
            "gpuCount": int(env("GPU_COUNT", "1")),
            "gpuTypeIds": [env("GPU_TYPE", "NVIDIA H200")],
            "gpuTypePriority": "availability",
            "containerDiskInGb": int(env("DISK_GB", "220")),
            "volumeInGb": 0, "volumeMountPath": "/workspace",
            "imageName": env("IMAGE", "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"),
            "templateId": env("TEMPLATE_ID", "runpod-torch-v280"),
            "ports": ["22/tcp"], "dataCenterPriority": "availability",
            "name": env("POD_NAME", "gpu-job"),
            "env": pod_env()}
    if env("VOLUME_ID"):
        base["networkVolumeId"] = env("VOLUME_ID")
        del base["volumeInGb"]
    if env("DATA_CENTERS") == "all":
        tiers = [[dc for tier in TIERS for dc in tier]]
    elif env("DATA_CENTERS"):
        tiers = [env("DATA_CENTERS").split(",")]
    elif env("VOLUME_ID"):
        raise SystemExit("VOLUME_ID set but no DATA_CENTERS — a network volume is region-locked; pass its region")
    else:
        tiers = TIERS
    deadline = time.time() + 60 * int(env("RETRY_MINUTES", "0"))
    attempt = 0
    while True:
        attempt += 1
        for tier in tiers:
            st, resp = post_rest("/pods", dict(base, dataCenterIds=tier))
            print(f"[deploy] attempt {attempt} tier {tier[:2]}... -> HTTP {st}", flush=True)
            if st in (200, 201):
                pid = resp.get("id") or resp.get("podId")
                print(f"[deploy] OK pod={pid} dc={resp.get('machine',{}).get('dataCenterId','?')} "
                      f"costPerHr={resp.get('costPerHr','?')}", flush=True)
                return pid
            print(f"  no go: {str(resp)[:160]}", flush=True)
        if time.time() >= deadline:
            raise SystemExit("[deploy] no stock in any tier"
                             + (f" after {attempt} attempts" if attempt > 1 else "")
                             + " (set RETRY_MINUTES=N to keep trying)")
        print(f"[deploy] no stock; retrying in 3 min "
              f"({int((deadline - time.time()) / 60)} min left)", flush=True)
        time.sleep(180)


def wait_ssh(pid):
    for i in range(40):
        time.sleep(8)
        try:
            p = gql('query { pod(input:{podId:"%s"}) { desiredStatus costPerHr runtime '
                    '{ uptimeInSeconds ports { ip publicPort privatePort type } } } }' % pid)["data"]["pod"]
        except Exception as e:
            print(f"  poll {i}: {e}", flush=True); continue
        rt = (p or {}).get("runtime")
        if rt and rt.get("ports"):
            for port in rt["ports"]:
                if port.get("privatePort") == 22 and port.get("ip"):
                    print(f"[ssh] ready: ip={port['ip']} port={port['publicPort']} "
                          f"costPerHr={p.get('costPerHr')}", flush=True)
                    return port["ip"], port["publicPort"], p.get("costPerHr")
        print(f"  poll {i}: runtime not ready (uptime={(rt or {}).get('uptimeInSeconds')})", flush=True)
    raise SystemExit(f"[ssh] endpoint not ready after ~5min — if uptime>0 with ports None, "
                     f"DELETE pod {pid} and redeploy (known provider failure mode; don't wait it out)")


if __name__ == "__main__":
    pid = deploy()
    ip, port, cost = wait_ssh(pid)
    print(f"\nPOD_ID={pid}")
    print(f"SSH=ssh -i {env('SSH_KEY_FILE', os.path.expanduser('~/.ssh/id_ed25519'))} -p {port} root@{ip}")
    print(f"COST_PER_HR={cost}")
