#!/usr/bin/env python3
"""Adds `mo sessions` to an upstream Mole source tree.

    apply_overlay.py <mole-source-dir>

Copies overlay/bin/sessions.sh into bin/ and makes five small, anchored edits:
the router case in `mole`, the command list (help + completion names), one help
example, and the bash/zsh/fish sub-command completions. Each edit finds an
exact upstream anchor. If upstream changed an anchor that `mo sessions` needs
(router, command list), this fails, so a broken build is never released. A
missing cosmetic anchor (help example, completions) is only a warning. Running
it twice changes nothing.
"""
import re
import shutil
import sys
from pathlib import Path

OVERLAY = Path(__file__).resolve().parent.parent / "overlay"
problems: list[str] = []

NOTICE = """# Modified copy: agent sessions overlay

This tree is the upstream Mole source (https://github.com/tw93/Mole, GPL-3.0)
modified by the agent-sessions-overlay project. It is unofficial and not
affiliated with or endorsed by the Mole project.

Changes:

- added `bin/sessions.sh` (the `mo sessions` command);
- `mole`: one router case for `sessions`, and "6. Sessions" in the main menu;
- `lib/core/commands.sh`: `sessions` in the command list;
- `lib/manage/update.sh`: one help example;
- `bin/completion.sh`: `sessions` sub-command completions for bash, zsh and fish;
- added this file.

Everything else is unchanged upstream code. Upstream's LICENSE (GPL-3.0)
applies to the whole tree.
"""


def edit(src: Path, rel: str, done_marker: str, pattern: str, insert: str, *, before: bool, required: bool) -> None:
    path = src / rel
    text = path.read_text()
    if done_marker in text:
        print(f"already patched: {rel} ({done_marker.strip()[:40]})")
        return
    m = re.search(pattern, text, re.M)
    if not m:
        msg = f"{rel}: upstream anchor not found ({pattern[:60]}...); update scripts/apply_overlay.py"
        if required:
            problems.append(msg)
        else:
            print(f"::warning::{msg}")
        return
    at = m.start() if before else m.end()
    path.write_text(text[:at] + insert + text[at:])
    print(f"patched: {rel}")


def main_menu_entry(src: Path) -> None:
    """Adds "6. Sessions" to the `mo` main menu: drawn line, ↓ limit, Enter
    and the 6 key. All four anchors must match or none is applied, so an
    upstream menu change can never leave a half-patched menu."""
    path = src / "mole"
    text = path.read_text()
    if "show_menu_option 6" in text:
        print("already patched: mole (main menu)")
        return
    steps = [
        (r'^( *)printf [^\n]*show_menu_option 5 "Status [^\n]*\n',
         lambda m: m.group(0) + m.group(1) + "printf '\\r\\033[2K%s\\n' \"$(show_menu_option 6 \"Sessions     "
         "Clean agent sessions\" \"$([[ $selected -eq 6 ]] && echo true || echo false)\")\"\n"),
        (r'\(\(current_option < 5\)\) && \(\(current_option\+\+\)\)',
         lambda m: "((current_option < 6)) && ((current_option++))"),
        (r'^( *)5\) launch_menu_command "\$SCRIPT_DIR/bin/status\.sh" ;;\n',
         lambda m: m.group(0) + m.group(1) + '6) launch_menu_command "$SCRIPT_DIR/bin/sessions.sh" ;;\n'),
        (r'^( *)"CHAR:5"\)\n\1    launch_menu_command "\$SCRIPT_DIR/bin/status\.sh"\n\1    ;;\n',
         lambda m: m.group(0) + m.group(1) + '"CHAR:6")\n' + m.group(1) + '    launch_menu_command '
         '"$SCRIPT_DIR/bin/sessions.sh"\n' + m.group(1) + "    ;;\n"),
    ]
    for pattern, _ in steps:
        if len(re.findall(pattern, text, re.M)) != 1:
            print(f"::warning::mole: main menu anchor not found ({pattern[:50]}...); "
                  "menu entry skipped, `mo sessions` still works")
            return
    for pattern, repl in steps:
        text = re.sub(pattern, repl, text, count=1, flags=re.M)
    path.write_text(text)
    print("patched: mole (main menu)")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = Path(sys.argv[1]).resolve()
    if not (src / "mole").is_file() or not (src / "bin").is_dir():
        print(f"::error::{src} is not a Mole source tree")
        return 1

    target = src / "bin" / "sessions.sh"
    shutil.copyfile(OVERLAY / "bin" / "sessions.sh", target)
    target.chmod(0o755)
    print("copied: bin/sessions.sh")

    # 1. Router: dispatch `mo sessions` like `mo slim`.
    edit(src, "mole", '"sessions")',
         r'^( *)"slim"\)\n\1    run_mole_command "\$SCRIPT_DIR/bin/slim\.sh" "\$\{args\[@\]:1\}"\n\1    ;;\n',
         '        "sessions")\n'
         '            run_mole_command "$SCRIPT_DIR/bin/sessions.sh" "${args[@]:1}"\n'
         '            ;;\n',
         before=False, required=True)

    # 2. Shared command list: `mo --help` and the completion command names.
    edit(src, "lib/core/commands.sh", '"sessions:',
         r'^ *"slim:[^"\n]*"\n',
         '    "sessions:Clean Claude Code, Codex and Antigravity sessions"\n',
         before=False, required=True)

    # 3. One help example.
    edit(src, "lib/manage/update.sh", 'mo sessions prune',
         r'^ *printf "[^\n]*"mo touchid enable --dry-run"[^\n]*\n',
         '    printf "  %s%-28s%s %s\\n" "$GREEN" "mo sessions prune --days 30" "$NC" '
         '"Trash agent sessions older than 30 days"\n',
         before=True, required=False)

    # 4-6. Sub-command completions.
    edit(src, "bin/completion.sh", 'sessions)\n                COMPREPLY',
         r'^            completion\)\n                COMPREPLY=\( \\\$\(compgen -W "bash zsh fish"',
         '            sessions)\n'
         '                COMPREPLY=( \\$(compgen -W "list show rm prune orphans trash restore empty-trash '
         '--agent --dry-run --purge --help" -- "\\$cur_word") )\n'
         '                ;;\n',
         before=True, required=False)
    edit(src, "bin/completion.sh", "printf '        sessions)",
         r"^        printf '        completion\)\\n'\n",
         "        printf '        sessions)\\n'\n"
         "        printf \"            _arguments '1:action:(list show rm prune orphans trash restore empty-trash)'\\n\"\n"
         "        printf '            ;;\\n'\n",
         before=True, required=False)
    edit(src, "bin/completion.sh", "local sessions_action",
         r"^    printf '\\n'\n    local shell_name\n",
         "    local sessions_action\n"
         "    for sessions_action in list show rm prune orphans trash restore empty-trash; do\n"
         "        printf 'complete -f -c %s -n \"__fish_seen_subcommand_from sessions\" -a %s\\n' \"$cmd\" \"$sessions_action\"\n"
         "    done\n",
         before=True, required=False)

    main_menu_entry(src)

    (src / "SESSIONS-OVERLAY.md").write_text(NOTICE)
    print("wrote: SESSIONS-OVERLAY.md")

    for p in problems:
        print(f"::error::{p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
