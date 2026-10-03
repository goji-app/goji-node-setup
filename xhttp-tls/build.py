#!/usr/bin/env python3
"""Embed templates/* into install.template.sh -> install.sh"""
import base64, io, os, tarfile
here = os.path.dirname(os.path.abspath(__file__))
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as t:
    for name in sorted(os.listdir(os.path.join(here, "templates"))):
        root = os.path.join(here, "templates", name)
        if not os.path.isdir(root):
            continue
        for dp, _, fs in os.walk(root):
            for f in sorted(fs):
                p = os.path.join(dp, f)
                ti = t.gettarinfo(p, arcname=os.path.relpath(p, os.path.join(here, "templates")).replace(os.sep, "/"))
                ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"; ti.mode = 0o644
                with open(p, "rb") as fh:
                    t.addfile(ti, fh)
b64 = base64.b64encode(buf.getvalue()).decode()
src = open(os.path.join(here, "install.template.sh"), encoding="utf-8").read()
prof = base64.b64encode(open(os.path.join(here, "xray-node-profile.json"), "rb").read()).decode()
open(os.path.join(here, "install.sh"), "w", encoding="utf-8", newline="\n").write(src.replace("__TEMPLATES_B64__", b64).replace("__PROFILE_B64__", prof))
print(f"install.sh built, templates archive {len(buf.getvalue())//1024} KB")
