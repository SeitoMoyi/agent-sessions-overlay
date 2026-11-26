# agent-sessions-overlay

Adds a `mo sessions` command to [Mole](https://github.com/tw93/Mole) (GPL-3.0), the macOS cleanup CLI. It lists and removes Claude Code, Codex and Antigravity sessions, and knows which ones [Codeg](https://codeg.app) has deleted. Each official Mole release is rebuilt with the command added. Unofficial and not affiliated with or endorsed by the Mole project.

```sh
mo sessions                      # pick sessions to remove in Mole's menu
mo sessions list -a claude       # table; -q KEYWORD, -n COUNT
mo sessions prune --days 30 -n   # preview, then drop -n to run
mo sessions orphans              # sessions deleted in Codeg whose files remain
mo sessions restore <BATCH>      # undo; removals go to ~/.agent-sessions-trash
mo sessions --help
```

The picker is Mole's own menu: `Space` selects, `A` selects all, `Enter` confirms, `S`/`O` sort, `/` searches, `Q` cancels. Running sessions are left out. Removals are listed in `mo history`.

## How it works

- `overlay/bin/sessions.sh` is the command. `scripts/apply_overlay.py` copies it into a Mole source tree. It then makes five small edits: the router case in `mole`, the command list, one help example, and the bash/zsh/fish completions. It also writes `SESSIONS-OVERLAY.md`, which lists the changes. Each edit finds an exact upstream anchor. If Mole changes the router or the command list, the build fails instead of shipping something broken.
- `.github/workflows/build.yml` runs every 6 hours. It reads Mole's latest release (`releases/latest`, which is always the macOS CLI). If this repo has no release for that version yet, it does the following on a macOS runner:
  - checks out that tag;
  - applies the overlay;
  - runs the shell syntax checks and Mole's own destructive-delete audit (ShellCheck only warns);
  - runs `scripts/smoke_test.sh`;
  - publishes `agent-sessions-overlay-<version>.tar.gz` and `SHA256SUMS` as a GitHub Release with the same tag as Mole's.
- `scripts/smoke_test.sh` creates fake sessions in a throwaway HOME and tests `list`, `prune -n`, `rm`, `orphans`, `restore`, the operations log and the help and completion wiring. It also drives the interactive picker through a pseudo-terminal, which catches changes to Mole's shared menu.
- A push that changes `overlay/` or `scripts/` rebuilds and re-releases the current version.
- `update-mole.sh` downloads the latest release and checks its SHA-256. It then runs Mole's own `install.sh` from it, which also fetches the official `analyze`/`status` binaries for that version.

## Setup

1. Push this folder to a **public** GitHub repo named `agent-sessions-overlay` (public repos get macOS runner minutes free).
2. In the repo, go to **Settings → Actions → General → Workflow permissions** and choose **Read and write permissions**.
3. Go to **Actions → Build with agent sessions → Run workflow**.
4. On your Mac, run:

   ```sh
   ./update-mole.sh
   ```

   Run it again whenever a new release appears. It does nothing if you're already up to date.

To rebuild a version, run the workflow with **force**. To build a specific version, enter it in **version** (e.g. `V1.74.0`).

## Notes

- **Use `update-mole.sh`, not `mo update`.** `mo update` installs the official Mole, which has no `mo sessions`; `update-mole.sh` puts it back. Your session trash is untouched either way.
- The installer asks for your password when the `mo` launcher is in a root-owned folder such as `/usr/local/bin`.
- GitHub switches off schedules in repos with no activity for 60 days. The workflow commits `LATEST` on every release to prevent that. If it ever gets switched off, re-enable it on the Actions tab.
- Settings for testing or other layouts: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `ANTIGRAVITY_DIR`, `CODEG_DB`, `AGENT_SESSIONS_TRASH`.

## License

GPL-3.0, the same as Mole, since `sessions.sh` runs on Mole's libraries. "Mole" is a trademark of the Mole project, so this fork uses its own name ([Mole's trademark policy](https://github.com/tw93/Mole/blob/main/TRADEMARK.md)).
