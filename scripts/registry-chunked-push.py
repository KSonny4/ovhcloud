#!/usr/bin/env python3
"""Chunked OCI blob upload (stdlib only) — pushes >100MB layers through a
100MB-capped edge (e.g. Cloudflare free tier) when the stock `docker push`
fails with 413 on its monolithic PUT.

Proven 2026-09-18 against registry.pkubelka.cz: 120MB blob (15 x 8MB
chunks) and 2.2GB blob (263 x 8MB chunks), both digest-identical on
pull-back, probe repos fully deleted after (manifest + blob DELETEs).
NomadSetup issue #8 carries the digests and verdicts.

Usage:
  1. Build the layer: tar -cf layer.tar <files> && gzip -k layer.tar
     diff_id=$(python3 -c "import hashlib; print(hashlib.sha256(open('layer.tar','rb').read()).hexdigest())")
  2. REGISTRY_USER=.. REGISTRY_PASSWORD=.. (Bao JIT, values never printed)
     python3 scripts/registry-chunked-push.py <host> <repo> <tag> layer.tar.gz <diff_id>
  3. Verify: docker pull <host>/<repo>:<tag> (Id must equal printed manifest digest).
  4. Delete probes: manifest DELETE then blob DELETEs per digest.

Notes: explicit User-Agent (Bot Fight Mode 1010s bare Python-urllib);
registry:2.8 answers lowercase header names; request OCI manifest
media types (modern docker stores OCI, schema2 Accept 404s).
"""

import base64
import hashlib
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

CHUNK = 8 * 1024 * 1024


def req(url, *, user, pw, method="GET", data=None, headers=None):
    tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
    h = {"Authorization": f"Basic {tok}",
         "User-Agent": "ge-probe-chunked-push/1.0"}
    h.update(headers or {})
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    ctx = ssl.create_default_context()
    try:
        resp = urllib.request.urlopen(r, timeout=120, context=ctx)
        low = {k.lower(): v for k, v in dict(resp.headers).items()}
        return resp.status, low, resp.read()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} on {method} {url}: {e.read()[:200]!r}")


def main() -> None:
    host, repo, tag, layer_path, diff_id = sys.argv[1:6]
    user = os.environ["REGISTRY_USER"]
    pw = os.environ["REGISTRY_PASSWORD"]
    base = f"https://{host}/v2/{repo}"
    with open(layer_path, "rb") as f:
        blob = f.read()
    blob_digest = "sha256:" + hashlib.sha256(blob).hexdigest()
    print(f"blob bytes={len(blob)} digest={blob_digest}")

    st, hd, _ = req(f"{base}/blobs/uploads/", user=user, pw=pw, method="POST")
    loc = hd["location"]
    print(f"upload session: {st}")
    for off in range(0, len(blob), CHUNK):
        part = blob[off : off + CHUNK]
        end = off + len(part) - 1
        st, hd, _ = req(
            loc, user=user, pw=pw, method="PATCH", data=part,
            headers={"Content-Type": "application/octet-stream",
                     "Content-Range": f"{off}-{end}"},
        )
        loc = hd.get("location", loc)
        print(f"chunk {off}-{end}: {st}")
    st, _, _ = req(f"{loc}&digest={blob_digest}" if "?" in loc else f"{loc}?digest={blob_digest}",
                   user=user, pw=pw, method="PUT")
    print(f"finalize: {st}")

    cfg = {"architecture": "amd64", "os": "linux",
           "rootfs": {"type": "layers", "diff_ids": [f"sha256:{diff_id}"]}}
    cfg_raw = json.dumps(cfg).encode()
    cfg_digest = "sha256:" + hashlib.sha256(cfg_raw).hexdigest()
    st, hd, _ = req(f"{base}/blobs/uploads/?digest={cfg_digest}", user=user, pw=pw,
                    method="POST")
    loc2 = hd["location"] + f"&digest={cfg_digest}"
    st2, _, _ = req(f"{loc2}", user=user, pw=pw, method="PUT", data=cfg_raw,
                    headers={"Content-Type": "application/octet-stream"})
    print(f"config {cfg_digest}: {st2}")

    manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                           "digest": cfg_digest, "size": len(cfg_raw)},
                "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                            "digest": blob_digest, "size": len(blob)}]}
    man_raw = json.dumps(manifest).encode()
    st, hd, _ = req(f"{base}/manifests/{tag}", user=user, pw=pw, method="PUT",
                    data=man_raw,
                    headers={"Content-Type": "application/vnd.oci.image.manifest.v1+json"})
    print(f"manifest {tag}: {st} digest={hd.get('docker-content-digest')}")


main()
