#!/usr/bin/env python3
"""Check the non-administrator security restrictions on a Portainer environment.

READ-ONLY. This script never writes. It deliberately needs no admin
credential: a standard-user API key can read environment settings, and
evidence gathering should not require the privilege being audited.

Intended use:

  1. Run it. Expect deviations, exit status 1.
  2. Flip the switches it names: select the environment -> Host -> Setup ->
     Docker security settings, then "Save configuration". The URL is
     https://<portainer>/#!/<environment-id>/docker/host/feat-config
  3. Run it again. Expect zero deviations, exit status 0.

Rollback, if the flip breaks something, is the same switches.

It can also be run later, from anywhere with API access, as a drift check.

Credentials: pass --key-file, or set PORTAINER_API_KEY_FILE. The key is read
from a file rather than an environment variable or an argument so it does not
land in shell history or another process's /proc/*/cmdline.
"""

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "https://localhost:9443"
# No default environment id. Every Portainer install numbers these
# differently, and the security-settings page looks identical on all of them —
# a wrong default here would silently audit the wrong host.
DEFAULT_KEY_FILE = os.environ.get("PORTAINER_API_KEY_FILE")

# What each setting should read once the environment is hardened, and why.
EXPECTED = (
    ("allowBindMountsForRegularUsers", False,
     "a bind of / is root on the host"),
    ("allowPrivilegedModeForRegularUsers", False,
     "privileged: true is root on the host"),
    ("allowHostNamespaceForRegularUsers", False,
     "pid: host escapes the container boundary"),
    ("allowDeviceMappingForRegularUsers", False,
     "raw device access reaches the disks"),
    ("allowContainerCapabilitiesForRegularUsers", False,
     "cap_add re-grants what cap_drop removed"),
    ("allowSysctlSettingForRegularUsers", False,
     "sysctls reach kernel tunables"),
    ("allowStackManagementForRegularUsers", True,
     "LOAD-BEARING: the sanctioned path for agent-operated stacks. If this "
     "is False, that work goes back to the raw Docker socket, which is worse"),
    ("allowVolumeBrowserForRegularUsers", False,
     "volume browsing reads other stacks' data, including credentials"),
    ("enableHostManagementFeatures", False,
     "host management exposes the host itself through the UI"),
)


def read_key(path):
    path = os.path.expanduser(path)
    try:
        with open(path) as fh:
            key = fh.read().strip()
    except OSError as e:
        print("error: cannot read API key from %s: %s" % (path, e.strerror),
              file=sys.stderr)
        sys.exit(2)
    if not key:
        print("error: %s is empty" % path, file=sys.stderr)
        sys.exit(2)
    return key


def fetch(base, endpoint_id, key, verify_tls):
    ctx = ssl.create_default_context()
    if not verify_tls:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(
        "%s/api/endpoints/%d" % (base, endpoint_id),
        headers={"X-API-Key": key})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:200]
        if e.code in (401, 403):
            print("error: HTTP %d reading environment %d. The API key is "
                  "wrong, revoked, or has no access to that environment."
                  % (e.code, endpoint_id), file=sys.stderr)
        else:
            print("error: HTTP %d reading environment %d: %s"
                  % (e.code, endpoint_id, detail), file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print("error: cannot reach %s: %s" % (base, e), file=sys.stderr)
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(
        description="Read-only check of a Portainer environment's "
                    "non-administrator security restrictions.")
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="Portainer base URL (default %s)" % DEFAULT_BASE)
    ap.add_argument("--endpoint-id", type=int, required=True,
                    help="environment id (required — see the Portainer URL "
                         "when the environment is selected)")
    ap.add_argument("--key-file", default=DEFAULT_KEY_FILE,
                    required=DEFAULT_KEY_FILE is None,
                    help="file holding the Portainer API key "
                         "(default: $PORTAINER_API_KEY_FILE)")
    ap.add_argument("--verify-tls", action="store_true",
                    help="verify the TLS certificate (Portainer's is "
                         "self-signed on localhost, so this is off by default)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only deviations")
    args = ap.parse_args()

    key = read_key(args.key_file)
    endpoint = fetch(args.base, args.endpoint_id, key, args.verify_tls)

    settings = endpoint.get("SecuritySettings")
    if not isinstance(settings, dict):
        print("error: environment %d returned no SecuritySettings object; is "
              "it a Docker environment?" % args.endpoint_id, file=sys.stderr)
        return 2

    print("environment %d: %s (%s)\n"
          % (args.endpoint_id, endpoint.get("Name"), endpoint.get("URL")))

    deviations = []
    if not args.quiet:
        print("  %-45s %-8s %-8s %s" % ("setting", "actual", "wanted", ""))
        print("  %-45s %-8s %-8s %s" % ("-" * 45, "-" * 8, "-" * 8, ""))

    for name, want, why in EXPECTED:
        actual = settings.get(name)
        ok = actual == want
        if not ok:
            deviations.append((name, actual, want, why))
        if not args.quiet:
            print("  %-45s %-8s %-8s %s"
                  % (name, actual, want, "ok" if ok else "DEVIATION"))

    if not deviations:
        print("\nAll %d settings match. Environment %d is in the expected "
              "state." % (len(EXPECTED), args.endpoint_id))
        return 0

    print("\n%d deviation(s):" % len(deviations))
    for name, actual, want, why in deviations:
        print("\n  %s is %s, wanted %s" % (name, actual, want))
        print("    %s" % why)

    print("""
Fix in the UI: select environment %s -> Host -> Setup -> Docker security
settings. Check the URL carries THIS environment's id -- the page looks
identical on every environment. The switches read "Hide ... for
non-administrators", so turning one ON clears the matching allow* field, and
"Hide the use of Stacks" must stay OFF. Click "Save configuration" at the
bottom; the toggles alone do not persist.

Re-run this script afterwards; it should report zero deviations.

Storing the settings is NOT proof they are ENFORCED on stack deploys.
Portainer documents these against the container-create form, and 2.39.2
shipped fixes for two bind-mount restriction bypasses. After the flip, test
both directions with the standard-user key: deploy a throwaway stack
declaring a bind mount -- it must be refused -- and redeploy a stack that
declares none, which must still succeed. Only the second half tells you
whether you have also locked yourself out of routine work."""
          % endpoint.get("Name"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
