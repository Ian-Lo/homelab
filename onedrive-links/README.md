# onedrive-links

CLI to list, create, and revoke OneDrive (personal) shared links via Microsoft Graph.

## Setup

1. Install deps:
   ```
   pip install -r requirements.txt
   ```

2. Register a free Azure app (one-time):
   - Go to https://portal.azure.com > App registrations > New registration
   - Name: anything (e.g. `onedrive-links-cli`)
   - Supported account types: **Personal Microsoft accounts only**
   - Redirect URI: leave blank
   - After creation, go to **Authentication** > **Allow public client flows** > set to **Yes** > Save
   - Go to **API permissions** > Add permission > Microsoft Graph > Delegated permissions:
     - `Files.ReadWrite.All`
     - `User.Read`
   - Copy the **Application (client) ID** from the Overview page

3. Export the client ID:
   ```
   export ONEDRIVE_LINKS_CLIENT_ID=<your-client-id>
   ```

## Usage

First run of any command triggers a device-code login (opens a browser, enter
the code shown). The token is cached in `~/.config/onedrive-links/token_cache.bin`
(mode 600) so you won't need to log in again until it expires.

```
# List all shared links under a folder (recursive; omit path for whole drive)
python3 onedrive_links.py list "Documents/Shared"

# Create a view-only anonymous link
python3 onedrive_links.py create "Documents/report.pdf" --type view --scope anonymous

# Create an edit link restricted to your org (n/a for personal accounts) with an expiration
python3 onedrive_links.py create "Documents/report.pdf" --type edit --expiration 2026-12-31T00:00:00Z

# Revoke a specific link
python3 onedrive_links.py revoke "Documents/report.pdf" --permission-id <id>

# Revoke all links on an item
python3 onedrive_links.py revoke "Documents/report.pdf" --all
```

`list` with no path walks the entire drive tree, which can be slow on large
accounts — pass a subfolder path to scope it down.

## Tests

```
pip install -r requirements-dev.txt
pytest
```

Tests mock the Graph API entirely (no network calls, no credentials needed).
