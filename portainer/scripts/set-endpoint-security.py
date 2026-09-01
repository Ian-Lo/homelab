#!/usr/bin/env python3
"""Set the non-administrator security restrictions on a Portainer environment.

Why this matters: Portainer's "for regular users" restrictions are permissive
by default. Left that way, any standard user with read-write access to a stack
can define `privileged: true`, a bind mount of `/`, `pid: host`, or a device
mapping, and deploy it — which is root on the Docker host, from a
non-administrator account.

PREFER THE UI. The reviewed path is: run verify-endpoint-security.py (needs no
admin credential), flip the six switches at

    https://<portainer>/#!/<environment-id>/docker/host/feat-config

(sidebar: pick the environment, then Host -> Setup; admin-only on CE), then run
the verifier again. That gets the same before/after evidence with no admin
credential in any script, and no write against an API contract you have not
confirmed on your build. Rollback is the same six switches. This script is the
alternative, not the recommendation.

This script REQUIRES ADMIN CREDENTIALS. A standard-user API key cannot change
environment settings, by design — which also means this is not a script to
hand to an automation account.

Default is a dry run: it reads the current settings and prints what it would
change. Nothing is written without --apply.

Usage:
  # show current settings and the proposed change, write nothing
  ./set-endpoint-security.py --endpoint-id N --username <admin>

  # apply the hardening
  ./set-endpoint-security.py --endpoint-id N --username <admin> --apply

  # put the six restrictions back the way they were (rollback)
  ./set-endpoint-security.py --endpoint-id N --username <admin> --revert --apply

Credentials: --username only, prompting for a password that is never echoed,
never read from a file, and never logged. There is deliberately NO environment
variable for an admin key -- that would put a root-equivalent credential into
shell history and into the process environment of everything it spawns.

The password and the JWT it is exchanged for are scrubbed from every printed
string, including exception text and HTTP error bodies.
"""

import argparse
import getpass
import json
import ssl
import sys
import urllib.error
import urllib.request

DEFAULT_BASE = "https://localhost:9443"
# No default environment id. The security-settings page looks identical on
# every environment, so a wrong default would silently harden the wrong host.

# The six restrictions this script manages. Hardened value is False for all.
MANAGED = (
    "allowBindMountsForRegularUsers",
    "allowPrivilegedModeForRegularUsers",
    "allowHostNamespaceForRegularUsers",
    "allowDeviceMappingForRegularUsers",
    "allowContainerCapabilitiesForRegularUsers",
    "allowSysctlSettingForRegularUsers",
)

# Never touched. This is the sanctioned path by which agents operate stacks at
# all; disabling it pushes that work back toward the raw Docker socket, which
# is strictly worse.
PROTECTED_TRUE = "allowStackManagementForRegularUsers"

_SECRETS = []


def scrub(text):
    """Remove any known secret from a string before it reaches a terminal."""
    out = str(text)
    for s in _SECRETS:
        if s:
            out = out.replace(s, "<REDACTED>")
    return out


def die(msg, code=1):
    print("error: " + scrub(msg), file=sys.stderr)
    sys.exit(code)


def make_ctx(verify):
    ctx = ssl.create_default_context()
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def request(ctx, base, path, headers, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = dict(headers)
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"message": raw[:300]}
    except Exception as e:
        die("transport failure talking to %s: %s" % (base, scrub(e)))


def authenticate(ctx, base, username):
    """Exchange an admin password for a JWT. No other credential path."""
    if not username:
        die("no credentials. Pass --username <admin>. There is deliberately no "
            "environment-variable path for an admin key here: it would land in "
            "shell history and in the environment of every child process. A "
            "standard-user key cannot change environment settings at all.")

    if not sys.stdin.isatty():
        die("--username needs a terminal to prompt for the password and this "
            "is not one. Run it interactively, or use the UI: Environments -> "
            "the environment -> Security settings.")

    password = getpass.getpass("Portainer password for %s: " % username)
    _SECRETS.append(password)
    st, body = request(ctx, base, "/api/auth", {}, "POST",
                       {"username": username, "password": password})
    if st != 200 or "jwt" not in body:
        die("authentication failed (HTTP %s): %s" % (st, scrub(body.get("message", body))))
    jwt = body["jwt"]
    _SECRETS.append(jwt)
    return {"Authorization": "Bearer " + jwt}, "password login as %s" % username


def fetch_settings(ctx, base, headers, endpoint_id):
    st, body = request(ctx, base, "/api/endpoints/%d" % endpoint_id, headers)
    if st == 403:
        die("HTTP 403 reading environment %d. These credentials are not an "
            "admin. Environment settings are admin-only." % endpoint_id)
    if st != 200:
        die("could not read environment %d (HTTP %s): %s"
            % (endpoint_id, st, scrub(body.get("message", body))))
    ss = body.get("SecuritySettings")
    if not isinstance(ss, dict):
        die("environment %d returned no SecuritySettings object; is it a "
            "Docker environment?" % endpoint_id)
    return body, ss


def write_settings(ctx, base, headers, endpoint_id, desired):
    """Write via the panel-specific settings route. One attempt, no fallback.

    PUT /api/endpoints/{id}/settings is the route for this panel in Portainer
    2.x. If it is rejected, that is a real answer about this build and the
    script stops -- retrying the same payload against the general
    endpoint-update route would be guessing at a permissions API, which is
    exactly the wrong thing to automate.
    """
    label = "PUT /api/endpoints/%d/settings" % endpoint_id
    st, body = request(ctx, base, "/api/endpoints/%d/settings" % endpoint_id,
                       headers, "PUT", {"securitySettings": desired})
    if 200 <= st < 300:
        return label
    print("\n%s -> HTTP %s: %s"
          % (label, st, scrub(body.get("message", body))), file=sys.stderr)
    die("the settings route rejected the change. Do NOT work around it by "
        "trying another route. Set them in the UI instead: Environments -> "
        "the environment -> Security settings, then confirm with "
        "verify-endpoint-security.py, which names the six switches.")


def main():
    ap = argparse.ArgumentParser(
        description="Harden (or revert) non-administrator restrictions on a "
                    "Portainer environment. Dry run unless --apply.")
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="Portainer base URL (default %s)" % DEFAULT_BASE)
    ap.add_argument("--endpoint-id", type=int, required=True,
                    help="environment id (required — see the Portainer URL "
                         "when the environment is selected)")
    ap.add_argument("--username",
                    help="admin username; prompts for a password (required)")
    ap.add_argument("--apply", action="store_true",
                    help="actually write the change (default is a dry run)")
    ap.add_argument("--revert", action="store_true",
                    help="set the six restrictions back to permissive")
    ap.add_argument("--verify-tls", action="store_true",
                    help="verify the TLS certificate (Portainer's is self-signed "
                         "on localhost, so this is off by default)")
    args = ap.parse_args()

    target = True if args.revert else False
    ctx = make_ctx(args.verify_tls)

    headers, how = authenticate(ctx, args.base, args.username)
    print("authenticated via %s" % how)

    endpoint, current = fetch_settings(ctx, args.base, headers, args.endpoint_id)
    print("environment %d: %s (%s)\n"
          % (args.endpoint_id, endpoint.get("Name"), endpoint.get("URL")))

    # The UI folds enableGPUManagement and gpus into the SAME settings PUT
    # (confirmed by reading the 2.39.5 frontend bundle), but the GET does not
    # return them inside SecuritySettings -- they sit at the top level of the
    # endpoint. This script deliberately does not send them, because it cannot
    # test that it round-trips them correctly. Refuse rather than silently
    # clear someone's GPU configuration.
    if endpoint.get("Gpus") or endpoint.get("EnableGPUManagement"):
        die("environment %d has GPU management configured (Gpus=%s, "
            "EnableGPUManagement=%s). Portainer sends GPU config in the same "
            "settings payload as these restrictions, and this script does not "
            "carry it, so writing here could clear it. Use the UI instead: "
            "Host -> Setup on that environment."
            % (args.endpoint_id, json.dumps(endpoint.get("Gpus")),
               endpoint.get("EnableGPUManagement")))

    changes = []
    print("  %-45s %-9s %s" % ("setting", "current", "proposed"))
    print("  %-45s %-9s %s" % ("-" * 45, "-" * 9, "-" * 8))
    for k in MANAGED:
        now = current.get(k)
        if now == target:
            print("  %-45s %-9s unchanged" % (k, now))
        else:
            print("  %-45s %-9s %s" % (k, now, target))
            changes.append(k)

    protected_now = current.get(PROTECTED_TRUE)
    print("  %-45s %-9s left alone (must stay True)" % (PROTECTED_TRUE, protected_now))
    if protected_now is not True:
        print("\nWARNING: %s is %s, not True. Agents cannot deploy stacks at all "
              "in this state, which pushes that work toward the raw Docker "
              "socket. Consider turning it back on."
              % (PROTECTED_TRUE, protected_now))

    if not changes:
        print("\nNothing to change; already in the requested state.")
        return 0

    if not args.apply:
        print("\nDry run. Re-run with --apply to write %d change(s)." % len(changes))
        return 0

    desired = dict(current)
    for k in MANAGED:
        desired[k] = target
    desired[PROTECTED_TRUE] = True

    route = write_settings(ctx, args.base, headers, args.endpoint_id, desired)
    print("\napplied via %s" % route)

    # Re-read rather than trusting the write's response body.
    _, after = fetch_settings(ctx, args.base, headers, args.endpoint_id)
    ok = True
    print("\nverification (re-read from the API):")
    for k in MANAGED:
        got = after.get(k)
        mark = "ok" if got == target else "MISMATCH"
        if got != target:
            ok = False
        print("  %-45s %-9s %s" % (k, got, mark))
    got = after.get(PROTECTED_TRUE)
    if got is not True:
        ok = False
        print("  %-45s %-9s MISMATCH -- should still be True" % (PROTECTED_TRUE, got))
    else:
        print("  %-45s %-9s ok" % (PROTECTED_TRUE, got))

    if not ok:
        die("the API accepted the write but the re-read disagrees. Check the "
            "UI before assuming anything is enforced.")

    if not args.revert:
        print("""
Settings are stored. That is NOT proof they are enforced on stack deploys --
Portainer documents them against the container-create form, and 2.39.2 shipped
fixes for two bind-mount restriction bypasses.

Test both directions with the standard-user key before you call this done:
  1. Try to deploy a throwaway stack that declares a bind mount. It must be
     REFUSED.
  2. Redeploy a stack that declares no capabilities, devices or binds. It must
     still SUCCEED.
  3. Expect any stack that does declare them to become admin-only to redeploy.
     That is the intended outcome, not a regression -- but find out now, not
     the next time one of them needs a restart.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
