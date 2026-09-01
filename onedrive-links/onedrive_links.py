#!/usr/bin/env python3
"""Manage OneDrive (personal) shared links via Microsoft Graph.

Setup: see README.md in this directory for how to register an Azure app
and set ONEDRIVE_LINKS_CLIENT_ID.
"""
import argparse
import json
import os
import stat
import sys
from pathlib import Path

import msal
import requests

CONFIG_DIR = Path.home() / ".config" / "onedrive-links"
CACHE_FILE = CONFIG_DIR / "token_cache.bin"
AUTHORITY = "https://login.microsoftonline.com/consumers"
SCOPES = ["Files.ReadWrite.All", "User.Read"]
GRAPH = "https://graph.microsoft.com/v1.0"


def get_client_id() -> str:
    client_id = os.environ.get("ONEDRIVE_LINKS_CLIENT_ID")
    if not client_id:
        client_id = input(
            "ONEDRIVE_LINKS_CLIENT_ID is not set. Register an Azure app "
            "(see README.md) and enter the client ID: "
        ).strip()
    if not client_id:
        sys.exit("No client ID provided.")
    return client_id


def load_cache() -> msal.SerializableTokenCache:
    cache = msal.SerializableTokenCache()
    if CACHE_FILE.exists():
        cache.deserialize(CACHE_FILE.read_text())
    return cache


def save_cache(cache: msal.SerializableTokenCache) -> None:
    if not cache.has_state_changed:
        return
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(cache.serialize())
    os.chmod(CACHE_FILE, stat.S_IRUSR | stat.S_IWUSR)


def get_token() -> str:
    cache = load_cache()
    app = msal.PublicClientApplication(
        get_client_id(), authority=AUTHORITY, token_cache=cache
    )

    accounts = app.get_accounts()
    result = None
    if accounts:
        result = app.acquire_token_silent(SCOPES, account=accounts[0])

    if not result:
        flow = app.initiate_device_flow(scopes=SCOPES)
        if "user_code" not in flow:
            sys.exit(f"Failed to start device flow: {flow}")
        print(flow["message"])
        result = app.acquire_token_by_device_flow(flow)

    save_cache(cache)

    if "access_token" not in result:
        sys.exit(f"Authentication failed: {result.get('error_description', result)}")
    return result["access_token"]


class GraphClient:
    def __init__(self, token: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"

    def get(self, path: str, **kwargs):
        resp = self.session.get(f"{GRAPH}{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()

    def post(self, path: str, json_body: dict):
        resp = self.session.post(f"{GRAPH}{path}", json=json_body)
        resp.raise_for_status()
        return resp.json()

    def delete(self, path: str):
        resp = self.session.delete(f"{GRAPH}{path}")
        resp.raise_for_status()

    def paged_get(self, path: str):
        items = []
        url = f"{GRAPH}{path}"
        while url:
            resp = self.session.get(url)
            resp.raise_for_status()
            data = resp.json()
            items.extend(data.get("value", []))
            url = data.get("@odata.nextLink")
        return items


def item_path_segment(path: str) -> str:
    path = path.strip("/")
    return f"root:/{path}:" if path else "root"


def walk_items(client: GraphClient, path: str):
    """Yield (item, full_path) for every file/folder under path, recursively."""
    root = client.get(f"/me/drive/{item_path_segment(path)}")
    yield from _walk(client, root, path.strip("/"))


def _walk(client: GraphClient, item: dict, current_path: str):
    yield item, current_path
    if "folder" not in item:
        return
    children = client.paged_get(f"/me/drive/items/{item['id']}/children")
    for child in children:
        child_path = f"{current_path}/{child['name']}" if current_path else child["name"]
        yield from _walk(client, child, child_path)


def cmd_list(client: GraphClient, args):
    found_any = False
    for item, full_path in walk_items(client, args.path):
        perms = client.paged_get(f"/me/drive/items/{item['id']}/permissions")
        link_perms = [p for p in perms if "link" in p and "type" in p["link"]]
        if not link_perms:
            continue
        found_any = True
        print(f"/{full_path}")
        for p in link_perms:
            link = p["link"]
            print(
                f"  [{p['id']}] {link.get('type', '?')}/{link.get('scope', '?')} "
                f"-> {link.get('webUrl', '?')}"
            )
    if not found_any:
        print("No shared links found.")


def resolve_item_id(client: GraphClient, path: str) -> str:
    item = client.get(f"/me/drive/{item_path_segment(path)}")
    return item["id"]


def cmd_create(client: GraphClient, args):
    item_id = resolve_item_id(client, args.path)
    body = {"type": args.type, "scope": args.scope}
    if args.password:
        body["password"] = args.password
    if args.expiration:
        body["expirationDateTime"] = args.expiration
    result = client.post(f"/me/drive/items/{item_id}/createLink", body)
    link = result["link"]
    print(f"Created: {link['webUrl']}")
    print(f"  type={link.get('type')} scope={link.get('scope')}")


def cmd_revoke(client: GraphClient, args):
    item_id = resolve_item_id(client, args.path)
    perms = client.paged_get(f"/me/drive/items/{item_id}/permissions")
    link_perms = [p for p in perms if "link" in p and "type" in p["link"]]

    if not link_perms:
        print("No shared links on this item.")
        return

    if args.permission_id:
        targets = [p for p in link_perms if p["id"] == args.permission_id]
        if not targets:
            sys.exit(f"No link permission with id {args.permission_id} on this item.")
    elif args.all:
        targets = link_perms
    else:
        print("Multiple/one link(s) found. Re-run with --permission-id or --all:")
        for p in link_perms:
            print(f"  [{p['id']}] {p['link'].get('webUrl', '?')}")
        return

    for p in targets:
        client.delete(f"/me/drive/items/{item_id}/permissions/{p['id']}")
        print(f"Revoked {p['id']} ({p['link'].get('webUrl', '?')})")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage OneDrive shared links.")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="List shared links under a path (recursive).")
    p_list.add_argument("path", nargs="?", default="", help="Path relative to OneDrive root")

    p_create = sub.add_parser("create", help="Create a shared link for a file/folder.")
    p_create.add_argument("path", help="Path relative to OneDrive root")
    p_create.add_argument("--type", choices=["view", "edit", "embed"], default="view")
    p_create.add_argument(
        "--scope", choices=["anonymous", "organization"], default="anonymous"
    )
    p_create.add_argument("--password", default=None)
    p_create.add_argument("--expiration", default=None, help="ISO 8601 datetime")

    p_revoke = sub.add_parser("revoke", help="Revoke shared link(s) for a file/folder.")
    p_revoke.add_argument("path", help="Path relative to OneDrive root")
    p_revoke.add_argument("--permission-id", default=None)
    p_revoke.add_argument("--all", action="store_true", help="Revoke all links on this item")

    return parser


def main():
    args = build_parser().parse_args()
    token = get_token()
    client = GraphClient(token)

    if args.command == "list":
        cmd_list(client, args)
    elif args.command == "create":
        cmd_create(client, args)
    elif args.command == "revoke":
        cmd_revoke(client, args)


if __name__ == "__main__":
    try:
        main()
    except requests.HTTPError as e:
        sys.exit(f"Graph API error: {e.response.status_code} {e.response.text}")
