# Maintenance tasks for the auzum orchard fork (merge-based integration).
#
# `main` is the single long-lived integration branch. It MERGES three sources
# (never rebases, never force-pushes):
#
#     zcash-upstream/main   zcash/orchard                     (real upstream)
#     zsa/zsa1              QED-it/orchard                    (Zcash Shielded Assets)
#     zakura-orchard        zakura-core/common crates/orchard (perf fork, grafted)
#
# Recipes:
#
#   just              alias for `just status`
#   just fetch        fetch all four remotes (no tags)
#   just sync         fetch, refresh `main-upstream`, regenerate `zakura-orchard`
#                     at the pinned zakura rev, then print status. Never touches
#                     `main`.
#   just status       what each source has that `main` lacks, a check of the
#                     dependency pins recorded on `main` against the vars below,
#                     and how far `zakura/main` has moved past the pin
#   just merge        merge upstream -> zsa -> zakura-orchard into `main`, one at a
#                     time, --no-ff, stopping at the first conflict. Re-run to
#                     continue after resolving. Requires a clean tree on `main`.
#   just pins         verify Cargo.toml pins the revs below and that no duplicate
#                     `zakura-*` crates exist in the dependency graph
#   just pins-apply   rewrite the rev strings in Cargo.toml to the vars below
#                     (for bumping pins; does not commit)
#   just check        cargo check --all-targets matrix: default / zsa-issuance /
#                     all features
#   just test         cargo test for default features, then with zsa-issuance
#                     (the circuit tests take several minutes)
#   just rerere-on    enable git rerere, so a redone/aborted merge replays your
#                     earlier conflict resolutions
#
# `zsa-rebased` is QED-it's zsa1 delta as one commit on zcash-upstream/main, for reading;
# `just merge` does not use it.
#
# Legacy branches `zakura-patches` and `zakura-rebased` come from
# an earlier rebase-based approach and are superseded; do not use them.

set shell := ["bash", "-uc"]

# --- integration sources -----------------------------------------------------

upstream_src := "zcash-upstream/main"
zsa_url      := "https://github.com/QED-it/orchard.git"   # the only ZSA source of truth
zsa_src      := "zsa/zsa1"
zakura_src   := "zakura-orchard"
upstream_mirror := "main-upstream"
zakura_script   := "scripts/zakura-orchard.sh"
# Regenerate `zakura-orchard` at the rev `main` pins, not at zakura/main: the
# monorepo and the halo2 fork must be bumped together (see `common_pin` below).
zakura_rev      := common_pin

# --- dependency pins that `main` must hold -----------------------------------
#
# Invariant: the halo2 fork pins the SAME zakura-core/common rev below for
# pasta_curves/sinsemilla, so exactly one copy of each `zakura-*` crate exists.

# halo2_proofs / halo2_gadgets / poseidon -> zakura-halo2-{proofs,gadgets,poseidon}
halo2_url := "https://github.com/auzum197/halo2.git"
halo2_pin := "edd368d4d0b703e27e3c115f40a02a5b1759c350"

# pasta_curves / sinsemilla / reddsa -> zakura-{pasta-curves,sinsemilla,reddsa}
common_url := "https://github.com/zakura-core/common.git"
common_pin := "66ddff6adf11ee134efef0e3e28ac5f72ea92824"

# -----------------------------------------------------------------------------

default: status

# Fetch every remote we integrate from. Refuse to fetch ZSA from anywhere but {{zsa_url}}.
fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    [ "$(git remote get-url zsa)" = "{{zsa_url}}" ] || { echo "remote zsa must be {{zsa_url}}; run: git remote set-url zsa {{zsa_url}}" >&2; exit 1; }
    git fetch --multiple zcash-upstream zsa zakura origin

# Refresh the mirror branches that `just merge` consumes. Never touches `main`.
sync: fetch
    #!/usr/bin/env bash
    set -euo pipefail

    current="$(git symbolic-ref --quiet --short HEAD || echo '(detached)')"

    if [[ "$current" == "{{upstream_mirror}}" ]]; then
        echo "error: {{upstream_mirror}} is checked out; switch to main first" >&2
        exit 1
    fi
    echo "==> {{upstream_mirror}} -> {{upstream_src}}"
    git branch -f "{{upstream_mirror}}" "{{upstream_src}}"
    git --no-pager log --oneline --no-decorate -n 1 "{{upstream_mirror}}"

    if [[ "$current" == "{{zakura_src}}" ]]; then
        echo "error: {{zakura_src}} is checked out; switch to main first" >&2
        exit 1
    fi
    echo
    echo "==> regenerating {{zakura_src}} from {{zakura_rev}}"
    if [[ ! -x "{{zakura_script}}" ]]; then
        echo "error: {{zakura_script}} is missing or not executable" >&2
        exit 1
    fi
    "{{zakura_script}}" "{{zakura_rev}}" "{{zakura_src}}"

    echo
    {{just_executable()}} --justfile "{{justfile()}}" status

# What each source still has that `main` lacks, and the state of the pins.
status:
    #!/usr/bin/env bash
    set -euo pipefail

    for src in "{{upstream_src}}" "{{zsa_src}}" "{{zakura_src}}"; do
        echo "=== $src"
        if ! git rev-parse --verify --quiet "$src^{commit}" >/dev/null; then
            echo "    missing ref (run \`just sync\` / \`just fetch\`)"
            echo
            continue
        fi
        if git merge-base --is-ancestor "$src" main; then
            echo "    already merged into main"
            echo
            continue
        fi
        ahead="$(git rev-list --count "main..$src")"
        echo "    $ahead commit(s) not in main:"
        git --no-pager log --oneline --no-decorate -n 5 "main..$src" | sed 's/^/      /'
        if [[ "$ahead" -gt 5 ]]; then echo "      ... $((ahead - 5)) more"; fi
        dupes="$(git cherry -v main "$src" 2>/dev/null | grep -c '^-' || true)"
        if [[ "${dupes:-0}" -gt 0 ]]; then
            echo "    ($dupes of them are patch-identical to commits already on main)"
        fi
        echo
    done

    echo "=== pins on main (Cargo.toml) vs justfile vars"
    manifest="$(git show main:Cargo.toml 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
        echo "    could not read main:Cargo.toml"
        exit 0
    fi
    rc=0
    for pair in "{{halo2_url}}|{{halo2_pin}}" "{{common_url}}|{{common_pin}}"; do
        url="${pair%%|*}"
        want="${pair##*|}"
        found="$(printf '%s\n' "$manifest" | grep -F "$url" | grep -oE 'rev = "[0-9a-fA-F]+"' | sed -E 's/.*"([0-9a-fA-F]+)".*/\1/' | sort -u || true)"
        if [[ -z "$found" ]]; then
            echo "    $url"
            echo "      main pins: (none found)  want: $want"
            rc=1
        elif [[ "$found" == "$want" ]]; then
            echo "    $url"
            echo "      ok: $want"
        else
            echo "    $url"
            echo "      main pins: $(printf '%s' "$found" | tr '\n' ' ')"
            echo "      justfile : $want   <-- MISMATCH (see \`just pins-apply\`)"
            rc=1
        fi
    done
    if [[ "$rc" -ne 0 ]]; then
        echo "    note: pins differ from the justfile vars (expected until the dependency-pin commits land on main)"
    fi

    echo
    echo "=== zakura commits available beyond the pin (bump both repos together)"
    if git rev-parse --verify --quiet "zakura/main^{commit}" >/dev/null; then
        echo "    $(git rev-list --count '{{common_pin}}..zakura/main') commit(s) in zakura/main beyond {{common_pin}}"
    else
        echo "    missing ref zakura/main (run \`just fetch\`)"
    fi

# Merge upstream -> zsa -> zakura-orchard into main, stopping at the first conflict.
merge:
    #!/usr/bin/env bash
    set -euo pipefail

    branch="$(git symbolic-ref --quiet --short HEAD || echo '(detached)')"
    if [[ "$branch" != "main" ]]; then
        echo "error: on '$branch'; \`just merge\` only runs on main" >&2
        exit 1
    fi
    if [[ -e "$(git rev-parse --git-dir)/MERGE_HEAD" ]]; then
        echo "error: a merge is still in progress." >&2
        echo "       resolve, \`git add\`, \`git commit\`, then run \`just merge\` again." >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "error: working tree has uncommitted changes; commit or stash them first" >&2
        git --no-pager status --short --untracked-files=no >&2
        exit 1
    fi

    for src in "{{upstream_src}}" "{{zsa_src}}" "{{zakura_src}}"; do
        if ! git rev-parse --verify --quiet "$src^{commit}" >/dev/null; then
            echo "error: $src does not exist; run \`just sync\`" >&2
            exit 1
        fi
        if git merge-base --is-ancestor "$src" main; then
            echo "==> $src: already merged"
            continue
        fi
        echo "==> merging $src"
        if ! git merge --no-ff --no-edit "$src"; then
            echo >&2
            echo "conflict merging $src." >&2
            echo "resolve, \`git add\`, \`git commit\`, then run \`just merge\` again to continue with the next source." >&2
            echo "(\`git merge --abort\` backs this merge out entirely.)" >&2
            exit 1
        fi
    done

    echo
    {{just_executable()}} --justfile "{{justfile()}}" pins

# Verify the dependency pins and that only one copy of each zakura-* crate exists.
pins:
    #!/usr/bin/env bash
    set -euo pipefail

    rc=0
    for pair in "{{halo2_url}}|{{halo2_pin}}" "{{common_url}}|{{common_pin}}"; do
        url="${pair%%|*}"
        want="${pair##*|}"
        found="$(grep -F "$url" Cargo.toml | grep -oE 'rev = "[0-9a-fA-F]+"' | sed -E 's/.*"([0-9a-fA-F]+)".*/\1/' | sort -u || true)"
        if [[ -z "$found" ]]; then
            echo "FAIL $url"
            echo "  - (no \`rev = \"...\"\` found on any line pinning this URL)"
            echo "  + $want"
            rc=1
        elif [[ "$found" != "$want" ]]; then
            echo "FAIL $url"
            while read -r rev; do echo "  - $rev"; done <<<"$found"
            echo "  + $want"
            rc=1
        else
            echo "ok   $url @ $want"
        fi
    done
    if [[ "$rc" -ne 0 ]]; then
        echo >&2
        echo "Cargo.toml pins do not match the justfile vars; run \`just pins-apply\` to rewrite them." >&2
        exit 1
    fi

    echo "==> cargo metadata"
    cargo metadata --format-version 1 >/dev/null

    # `--depth 0` lists only the duplicated packages themselves; without it the
    # reverse-dependency trees of unrelated duplicates (rand_core 0.6 vs 0.10,
    # ...) mention the zakura crates and the grep matches spuriously.
    echo "==> cargo tree -d (expect no zakura-* duplicates)"
    dupes="$(cargo tree -d --depth 0 2>/dev/null | grep -i zakura || true)"
    if [[ -n "$dupes" ]]; then
        echo "FAIL duplicate zakura-* crates in the graph:" >&2
        printf '%s\n' "$dupes" >&2
        echo "the halo2 fork must pin the same zakura-core/common rev as this crate ({{common_pin}})." >&2
        exit 1
    fi
    echo "ok   exactly one copy of each zakura-* crate"

# Rewrite the rev strings in Cargo.toml to the justfile vars. Does not commit.
pins-apply:
    #!/usr/bin/env bash
    set -euo pipefail

    for pair in "{{halo2_url}}|{{halo2_pin}}" "{{common_url}}|{{common_pin}}"; do
        url="${pair%%|*}"
        want="${pair##*|}"
        if ! grep -qF "$url" Cargo.toml; then
            echo "warning: Cargo.toml has no dependency on $url; nothing to rewrite" >&2
            continue
        fi
        tmp="$(mktemp "${TMPDIR:-/tmp}/Cargo.toml.XXXXXX")"
        sed -E "\%${url}% s%rev = \"[0-9a-fA-F]+\"%rev = \"${want}\"%" Cargo.toml >"$tmp"
        mv "$tmp" Cargo.toml
        echo "set $url -> $want"
    done
    git --no-pager diff --stat -- Cargo.toml || true
    echo "Cargo.toml rewritten (not committed). Run \`just pins\` to verify."

# `--all-targets` is deliberate: benches, tests and examples are the first
# things a merge breaks (a changed call signature lands in `benches/` long
# before it lands in `src/`), and a bare `cargo check` never compiles them.
#
# cargo check --all-targets matrix; stops at the first failing configuration.
check:
    #!/usr/bin/env bash
    set -euo pipefail

    run() {
        echo "==> cargo check --all-targets $*"
        if ! cargo check --all-targets "$@"; then
            echo "FAILED: cargo check --all-targets $*" >&2
            exit 1
        fi
    }
    run
    run --features zsa-issuance
    run --all-features
    echo "all check configurations passed"

# Tests for default features, then with ZSA issuance. The circuit tests take several minutes.
test:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> cargo test --release"
    cargo test --release
    echo "==> cargo test --release --features zsa-issuance,test-dependencies (slow: proving)"
    cargo test --release --features zsa-issuance,test-dependencies

# Remember conflict resolutions, so a retried or redone merge replays them.
rerere-on:
    #!/usr/bin/env bash
    set -euo pipefail
    git config rerere.enabled true
    git config rerere.autoupdate true
    echo "rerere enabled (rerere.enabled, rerere.autoupdate)"
