#!/usr/bin/env python3
"""gpu-job: deploy a disposable GPU pod (RunPod backend) and wait for direct SSH.

Config: ~/.config/gpu-job/env (KEY=VAL lines, written by gpu_job_init.sh); process env
overrides. Required: RUNPOD_API_KEY (or API_KEY_ENV=<var name> to read another), SSH_PUBLIC_KEY. Knobs (env): GPU_TYPE (default
"NVIDIA H200"), GPU_COUNT (1), DISK_GB (220), POD_NAME ("gpu-job"), IMAGE, TEMPLATE_ID,
DATA_CENTERS (comma list, or "all" = every pod-creatable DC; overrides tiered retry), VOLUME_ID
(network volume; requires DATA_CENTERS), RETRY_MINUTES (keep retrying ~3-min cycles until
stock appears or the deadline passes — scarce multi-GPU stock can take an hour; default 0 =
single pass), PASS_ENV (comma list of extra var names to inject into the pod's env).
If RCLONE_CONF_B64 is set (by init, from your rclone.conf remote), it is injected so the
pod can read/write your artifact store.

Prints POD_ID / SSH / COST_PER_HR. Region coverage is derived LIVE from RunPod's pod-creatable
DC set (dataCenters listed=true) and searched in geographic preference tiers (US-west→central→
east→EU→rest-of-world); `--selftest` runs the offline region-selection unit check.
Battle-tested lineage: extracted from a research lab's deploy after three independent
hand-rolled variants in one day; the 220GB default exists because 30GB kills any pod
that downloads a large base model.
"""
import json, os, sys, time, urllib.request, urllib.error

CFG = os.path.expanduser("~/.config/gpu-job/env")
_SELFTEST = "--selftest" in sys.argv  # offline unit check — must not require RunPod creds


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
KEY = env(KEY_NAME, required=not _SELFTEST)        # --selftest is offline: don't require creds to import
PUBLIC_KEY = env("SSH_PUBLIC_KEY", required=not _SELFTEST)

# Region coverage is derived LIVE from RunPod's `dataCenters(listed=true)` set (the pod-creatable
# subset) — a hand-maintained list rots (it drifts out of date AND accretes now-unlisted ids that
# schema-reject a batch). `_FALLBACK_DCS` is a BACKSTOP only, used iff the live query fails; it is
# the `listed: true` set as of 2026-06-17 and is never sent as one all-or-nothing batch (see
# select_tiers), so a stale id can only no-go its own small bucket.
_FALLBACK_DCS = [
    "US-CA-2", "US-WA-1", "US-TX-3", "US-TX-4", "US-KS-2", "US-IL-1",
    "US-MO-1", "US-MO-2", "US-NE-1", "US-GA-2", "US-NC-1", "US-NC-2", "US-MD-1",
    "EU-RO-1", "EU-CZ-1", "EU-NL-1", "EU-FR-1", "EU-SE-1",
    "EUR-IS-1", "EUR-IS-2", "EUR-IS-3", "EUR-IS-4", "EUR-NO-1", "EUR-NO-2",
    "CA-MTL-1", "CA-MTL-3", "CA-MTL-4", "AP-IN-1", "AP-JP-1", "OC-AU-1",
]

# Geographic preference: ordered (label, prefix-tuple). A DC joins the FIRST tier whose prefix it
# matches; anything unmatched falls into a final catch-all tier — so a brand-new RunPod region prefix
# is still searched (just last), never silently dropped. Preserves the prior US-west -> central ->
# east -> EU order and adds rest-of-world (CA/AP/OC/…) so the default path reaches it too.
_TIER_RULES = [
    ("us-west",    ("US-WA", "US-CA", "US-OR", "US-NV")),
    ("us-central", ("US-TX", "US-KS", "US-IL", "US-MO", "US-NE", "US-MN", "US-ND", "US-SD")),
    ("us-east",    ("US-GA", "US-NC", "US-MD", "US-DE", "US-PA", "US-VA", "US-NY")),
    ("eu",         ("EU-", "EUR-")),
    ("row",        ("CA-", "AP-", "OC-", "SEA-", "SA-", "ME-", "AF-")),
]


def listed_dcs(payload):
    """Pure: pod-creatable (listed=true) DC ids from a GraphQL `dataCenters{id listed}` payload, sorted."""
    dcs = (payload or {}).get("data", {}).get("dataCenters") or []
    return sorted({d["id"] for d in dcs if d.get("id") and d.get("listed")})


def tiered(dcs):
    """Pure: bucket DC ids into geographic preference tiers; unmatched prefixes -> a final catch-all
    tier. Returns the non-empty id-lists in preference order (every input id appears exactly once)."""
    buckets = [[] for _ in _TIER_RULES]
    catch = []
    for dc in dcs:
        for i, (_, prefixes) in enumerate(_TIER_RULES):
            if any(dc == p or dc.startswith(p) for p in prefixes):
                buckets[i].append(dc)
                break
        else:
            catch.append(dc)
    tiers = [b for b in buckets if b]
    if catch:
        tiers.append(catch)
    return tiers


def select_tiers(mode, dcs, live):
    """Pure: (DATA_CENTERS mode, creatable dcs, live?) -> ordered list of dataCenterId batches to try.
    - mode == "all": one batch of every live id (valid enum, safe) — or, if only the static fallback is
      available (live=False), the geographic buckets, so a possibly-stale id can't poison the whole batch.
    - mode == "<csv>": the operator's explicit list, verbatim (one batch).
    - mode falsy (default): geographic preference tiers."""
    if mode == "all":
        return [list(dcs)] if live else tiered(dcs)
    if mode:
        return [[d.strip() for d in mode.split(",") if d.strip()]]
    return tiered(dcs)


def creatable_dcs():
    """(ids, live): live `listed=true` DC set from RunPod GraphQL, or the static fallback if it fails."""
    try:
        ids = listed_dcs(gql("query { dataCenters { id listed } }"))
        if ids:
            return ids, True
        print("[deploy] live dataCenters query returned none; using static fallback list", flush=True)
    except Exception as e:
        print(f"[deploy] live dataCenters query failed ({e}); using static fallback list", flush=True)
    return list(_FALLBACK_DCS), False


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
    mode = env("DATA_CENTERS")
    if mode and mode != "all":
        tiers = select_tiers(mode, None, True)                  # explicit csv: verbatim, no DC lookup
    elif env("VOLUME_ID") and not mode:
        raise SystemExit("VOLUME_ID set but no DATA_CENTERS — a network volume is region-locked; pass its region")
    else:                                                       # mode == "all" or unset (default)
        dcs, live = creatable_dcs()
        tiers = select_tiers(mode, dcs, live)
        print(f"[deploy] region set: {sum(len(t) for t in tiers)} DC(s) in {len(tiers)} tier(s) "
              f"(source={'live' if live else 'fallback'}, mode={mode or 'default'})", flush=True)
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


def _selftest():
    """Offline unit check of the region-selection contract (no network, no pod, no creds)."""
    payload = {"data": {"dataCenters": [
        {"id": "US-WA-1", "listed": True}, {"id": "US-CA-2", "listed": True},
        {"id": "US-TX-3", "listed": True}, {"id": "US-GA-2", "listed": True},
        {"id": "EU-FR-1", "listed": True}, {"id": "AP-JP-1", "listed": True},
        {"id": "CA-MTL-3", "listed": True}, {"id": "ZZ-NEW-1", "listed": True},   # unknown prefix
        {"id": "US-TX-1", "listed": False}, {"id": "EUR-IS-5", "listed": False},  # unlisted -> excluded
    ]}}
    ids = listed_dcs(payload)
    assert "US-TX-1" not in ids and "EUR-IS-5" not in ids, "unlisted DCs must be excluded"
    assert ids == ["AP-JP-1", "CA-MTL-3", "EU-FR-1", "US-CA-2", "US-GA-2", "US-TX-3", "US-WA-1", "ZZ-NEW-1"], ids
    t = tiered(ids)
    assert t[0] == ["US-CA-2", "US-WA-1"], t[0]                  # us-west first, sorted within tier
    assert t[-1] == ["ZZ-NEW-1"], t                              # unknown prefix -> final catch-all, never dropped
    assert sorted(dc for tier in t for dc in tier) == ids, "every listed DC appears exactly once"
    assert select_tiers("all", ids, True) == [list(ids)], "all+live -> one batch of every id"
    assert select_tiers("all", ids, False) == t, "all+fallback -> geographic buckets (blast-radius-limited)"
    assert select_tiers("US-CA-2, EU-FR-1", ids, True) == [["US-CA-2", "EU-FR-1"]], "explicit csv verbatim"
    assert select_tiers(None, ids, True) == t, "default -> tiers"
    assert listed_dcs({}) == [] and tiered([]) == [], "empty payload is safe"
    assert _FALLBACK_DCS and all(d == d.strip() and "-" in d for d in _FALLBACK_DCS), "fallback list well-formed"
    print(f"deploy_pod selftest OK: {len(ids)} DCs -> {len(t)} tiers")


if __name__ == "__main__":
    if _SELFTEST:
        _selftest(); raise SystemExit(0)
    pid = deploy()
    ip, port, cost = wait_ssh(pid)
    print(f"\nPOD_ID={pid}")
    print(f"SSH=ssh -i {env('SSH_KEY_FILE', os.path.expanduser('~/.ssh/id_ed25519'))} -p {port} root@{ip}")
    print(f"COST_PER_HR={cost}")
