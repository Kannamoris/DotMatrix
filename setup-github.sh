#!/usr/bin/env bash
#
# Push DotMatrix to GitHub so the macOS runner can build it.
#
#   ./setup-github.sh <owner>/<repo>            # SSH (default)
#   ./setup-github.sh <owner>/<repo> --https    # HTTPS instead
#   ./setup-github.sh https://github.com/o/r.git
#
# Creates the repo automatically if the `gh` CLI is installed and logged in;
# otherwise tells you to create an empty one first.

set -euo pipefail

cd "$(dirname "$0")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

info()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()   { printf '%s error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

REPO_SPEC=""
SCHEME="ssh"
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --https) SCHEME="https" ;;
        --ssh)   SCHEME="ssh" ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)  REPO_SPEC="$1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- preflight

info "Checking the working tree"

[ -d .git ] || die "not a git repository — run this from the DotMatrix folder"
git rev-parse HEAD >/dev/null 2>&1 || die "no commits yet; commit before pushing"
[ -f .github/workflows/build.yml ] || die "missing .github/workflows/build.yml"
[ -f DotMatrix.xcodeproj/xcshareddata/xcschemes/DotMatrix.xcscheme ] \
    || die "missing shared scheme — CI needs it for 'xcodebuild -scheme'"

ok "repository has $(git rev-list --count HEAD) commit(s) on $(git branch --show-current)"

# A cartridge image must never end up in the repository. .gitignore covers the
# usual extensions, but check what is actually tracked rather than trusting it.
info "Checking for cartridge images or saves in tracked files"
LEAKED=$(git ls-files | grep -Ei '\.(gba|gb|gbc|sav|srm|rtc)$' || true)
if [ -n "$LEAKED" ]; then
    printf '%s\n' "$LEAKED" | sed 's/^/      /'
    die "the above are tracked by git — remove them before pushing (git rm --cached <file>)"
fi

# Anything over a megabyte is almost certainly a ROM that slipped past the
# extension check.
BIG=$(git ls-files -z | xargs -0 -I{} sh -c 'f="{}"; [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 1048576 ] && echo "$f"' 2>/dev/null || true)
if [ -n "$BIG" ]; then
    printf '%s\n' "$BIG" | sed 's/^/      /'
    die "the above tracked files are over 1 MB — check none of them is a cartridge image"
fi
ok "no cartridge data tracked"

if ! git diff --quiet || ! git diff --cached --quiet; then
    warn "you have uncommitted changes; they will not be pushed"
fi

# ------------------------------------------------------------ resolve remote

if [ -z "$REPO_SPEC" ]; then
    printf '\n'
    read -r -p "GitHub repo (owner/name): " REPO_SPEC
    [ -n "$REPO_SPEC" ] || die "no repository given"
fi

# Accept owner/name, a full https URL, or an SSH URL.
case "$REPO_SPEC" in
    git@github.com:*)
        REMOTE_URL="$REPO_SPEC"
        SLUG="${REPO_SPEC#git@github.com:}"; SLUG="${SLUG%.git}"
        ;;
    https://github.com/*)
        SLUG="${REPO_SPEC#https://github.com/}"; SLUG="${SLUG%.git}"
        REMOTE_URL="$REPO_SPEC"
        ;;
    */*)
        SLUG="$REPO_SPEC"
        if [ "$SCHEME" = "https" ]; then
            REMOTE_URL="https://github.com/${SLUG}.git"
        else
            REMOTE_URL="git@github.com:${SLUG}.git"
        fi
        ;;
    *)
        die "expected owner/name or a GitHub URL, got: $REPO_SPEC"
        ;;
esac

OWNER="${SLUG%%/*}"
NAME="${SLUG##*/}"

# ------------------------------------------------------------- create if able

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh repo view "$SLUG" >/dev/null 2>&1; then
        ok "repo $SLUG already exists"
    else
        info "Creating $SLUG with gh"
        # Private by default. macOS runner minutes bill at 10x on private
        # repos; make it public if you would rather not spend them.
        gh repo create "$SLUG" --private --disable-wiki
        ok "created $SLUG (private)"
    fi
else
    warn "gh CLI not available — create an empty repo named '$NAME' under '$OWNER' first"
    warn "do not add a README, .gitignore or licence; the push must be into an empty repo"
fi

# ------------------------------------------------------------- wire it up

CURRENT=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$CURRENT" ]; then
    git remote add origin "$REMOTE_URL"
    ok "added remote origin -> $REMOTE_URL"
elif [ "$CURRENT" != "$REMOTE_URL" ]; then
    warn "origin currently points at $CURRENT"
    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "      repoint it to $REMOTE_URL? [y/N] " reply
        case "$reply" in [yY]*) ;; *) die "left origin unchanged" ;; esac
    fi
    git remote set-url origin "$REMOTE_URL"
    ok "origin -> $REMOTE_URL"
else
    ok "origin already -> $REMOTE_URL"
fi

BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "main" ]; then
    warn "on branch '$BRANCH', but the workflow triggers on 'main'"
    if [ "$ASSUME_YES" -eq 0 ]; then
        read -r -p "      rename '$BRANCH' to 'main'? [y/N] " reply
        case "$reply" in [yY]*) git branch -M main; BRANCH=main ;; *) ;; esac
    fi
fi

# ------------------------------------------------------------------- push

printf '\n'
info "About to push"
printf '      %s%s commit(s) on %s -> %s%s\n' \
    "$DIM" "$(git rev-list --count HEAD)" "$BRANCH" "$REMOTE_URL" "$RESET"

if [ "$ASSUME_YES" -eq 0 ]; then
    read -r -p "      proceed? [y/N] " reply
    case "$reply" in [yY]*) ;; *) die "aborted; nothing was pushed" ;; esac
fi

if ! git push -u origin "$BRANCH"; then
    printf '\n'
    if [ "$SCHEME" = "ssh" ]; then
        warn "if that was an SSH key problem, check:  ssh -T git@github.com"
        warn "or re-run over HTTPS:  ./setup-github.sh $SLUG --https"
    else
        warn "HTTPS pushes need a personal access token as the password,"
        warn "not your account password: https://github.com/settings/tokens"
    fi
    die "push failed"
fi

printf '\n'
ok "pushed"
printf '\n'
printf '  Build:    https://github.com/%s/actions\n' "$SLUG"
printf '  Artifacts appear on the run page once the job finishes.\n'
printf '\n'
printf '  %sThe first run is expected to fail.%s Roughly 6,500 lines of Swift that\n' "$BOLD" "$RESET"
printf '  have never been compiled. The run summary groups every error by file,\n'
printf '  so start there rather than in the raw log.\n'
printf '\n'
