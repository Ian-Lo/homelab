# claude-statusline

Source of truth for the Claude Code statusline across every machine and
config profile you use it on.

The installed `~/.claude/statusline.sh` is a deployed artefact, not the master.
Edit the file here, commit, then run `install.sh` on each host. Same pattern as
`media-stack/install-on-host.sh`.

| File | What it is |
|---|---|
| `statusline.sh` | The statusline itself — model, account, prompt count, cwd, branch, context usage, rate-limit bar, caveman badge |
| `hooks/caveman-statusline.sh` | Badge renderer, exec'd by `statusline.sh` |
| `install.sh` | Installs into local config profiles; `--check` reports drift |
| `copy-statusline.sh` | Pulls this repo on a remote host and runs `install.sh` there |

## Install

```sh
./install.sh --all-profiles     # every ~/.claude* with a settings.json
./install.sh                    # just ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
./install.sh ~/.claude-JP       # a named profile
```

It writes a real file per profile (no symlinks — see below), `chmod 755`, and
jq-merges only the `statusLine` key into that profile's `settings.json`,
backing the file up first. Everything else in `settings.json` is per-machine
and is left alone.

Requires `jq`, `awk`, `git`. Without `jq` the statusline renders an empty line
rather than erroring, so the install pre-flights it.

## Drift

```sh
./install.sh --check --all-profiles     # exit 1 and a diff summary on drift
./copy-statusline.sh myserver.example youruser   # pull + install + check, remotely
```

`--check` compares `git hash-object` of each installed file against the
checkout's blob, so both hosts measure the same identity and neither host's
live copy becomes an accidental master. It also asserts mode 755, not a
symlink, owned by the invoking user, and that `settings.json` invokes that
profile's own `statusline.sh`.

That last test resolves the path rather than string-matching it. macOS is
case-insensitive, so a hand-written `$HOME/.claude-jp/statusline.sh` addresses
the real `.claude-JP` directory and is not drift; on ext4 the two differ and it
is.

## Two rules that are load-bearing

**No symlinks on the exec path.** `settings.json` execs `statusline.sh`, which
execs `hooks/caveman-statusline.sh`. A symlink at either point is a redirection
that `--check` cannot attribute, so `install.sh` replaces one with a real file.
Sharing one script between profiles via
`~/.claude-alt/statusline.sh -> ~/.claude/statusline.sh` is the obvious way to
avoid duplication and is exactly what this rules out; each profile gets its own
real copy instead.

**The badge script is resolved from user-level paths only.** `statusline.sh`
searches `$CLAUDE_CONFIG_DIR/hooks/` then `~/.claude/hooks/`, and requires a
regular file, not a symlink, owned by the caller, executable. It deliberately
does **not** look in `$CLAUDE_PROJECT_DIR/.claude/hooks/`: the wrapper execs
whatever it finds on every render — roughly every keystroke, with no prompt —
so a project-relative candidate would be arbitrary code execution straight from
`git clone`. Claude Code's hook-approval gate covers `.claude/settings.json`
hooks, not a path this wrapper execs itself. Search order does not fix it (a
project copy still wins whenever the user-level one is absent, i.e. on a fresh
host) and neither does an env-var opt-in (a repo can set env vars via direnv).
Do not re-add it.

The badge script used to live at the profile root (`~/.claude/caveman-statusline.sh`).
The resolver no longer reads that path; `install.sh` and `--check` warn about a
leftover but do not delete it — removing a file the operator placed is theirs to
do.

## Caveman badge

The badge renders only when `$CLAUDE_CONFIG_DIR/.caveman-active` exists *and*
`$CLAUDE_CONFIG_DIR/.caveman-active-session` names the statusline's own
`session_id` (from the same JSON `statusline.sh` pipes in) — absent either
condition, the segment is silently omitted and no separator is left behind.
**The mode-tracker hooks that write those two files are not in this repo.**
The statusline only *reads* them, so the contract between the two halves is
just the two filenames:

| Path | Meaning |
|---|---|
| `$CLAUDE_CONFIG_DIR/.caveman-active` | caveman mode is on |
| `$CLAUDE_CONFIG_DIR/.caveman-active-session` | the `session_id` that turned it on |

Anything that maintains those two files works — a pair of Claude Code hooks
is simply the convenient way to do it. Keeping them project-scoped, rather
than installing them user-wide, is deliberate: user-wide means jq-merging a
`hooks` key into `settings.json`, a wider blast radius than the `statusLine`
key this installer touches, and hooks declared in a project's own
`settings.json` still go through Claude Code's approval prompt. Without any
such hooks, `/caveman <mode>` will not update either file and they have to be
written by hand.

The session check exists because `.caveman-active` alone is a single value
shared by every session pointed at the same config dir — there's no
`SessionEnd` hook to clear it, so without the owner-session check, any
session activating caveman makes the badge render `[CAVEMAN]` for every
*other* session sharing that config dir too, including ones that never ran
`/caveman`. Whatever writes the flag must therefore write and clear the owner
file in the same breath — one paired write, one paired clear, no exceptions —
or the badge outlives the session that asked for it. The check fails closed: a
missing owner file, a missing `session_id` on stdin, or a mismatch between
them all mean "render nothing," never a fallback to the old flag-only
behavior.
