#!/usr/bin/env bash
# Refuse a tree that carries a credential, and with a base, the commits since it. Patterns, not a vendor tool: readable
# by every agent here.
#
#   scripts/scan-secrets.sh          the tracked files (the index's list, the working tree's bytes)
#   scripts/scan-secrets.sh BASE     those, and every line a commit in BASE..HEAD adds: a key committed and then
#                                    removed inside a pull request leaves its tree clean and stays in its history
#
# A hit names the file, the line and the pattern, never the text: that line holds the credential, and printing it
# would put the key into the CI log or the session transcript that the scan just kept it out of git for.
# Exit 0 clean, 1 a hit, 2 the scan could not run (no repo, BASE not a commit here, or a shallow history that cuts
# BASE..HEAD short), which says nothing about the tree. scripts/scan-secrets.test.sh runs it offline.
# `command grep` bypasses any shell function named grep (Claude Code defines one that honours .gitignore).
set -u
# Bytes, not characters: under a UTF-8 locale grep -I takes a matching line that holds one invalid byte for binary
# and prints nothing, though it matched.
export LC_ALL=C
setup() { echo "scan-secrets: $*: nothing was scanned" >&2; exit 2; }
[ $# -le 1 ] || setup "usage: scan-secrets.sh [BASE]"
top=$(git rev-parse --show-toplevel 2>/dev/null) || setup "not inside a git repository"
cd "$top" || setup "can't enter $top"

# A private JWK's "d" member in any spelling: JSON with any whitespace, an escaped JSON string inside JSON,
# a JS/TS object literal, single quotes. Read from a quoted heredoc so no quote needs escaping here.
jwk=$(cat <<'EOF'
(\\?["']d\\?["']|\bd)[[:space:]]*:[[:space:]]*\\?["'][A-Za-z0-9_-]{40,}
EOF
)
# Each pattern by the name a hit reports. GitHub's token prefixes: ghp_ classic, gho_ OAuth (what `gh auth login`
# stores), ghu_ user-to-server, ghs_ server-to-server, ghr_ refresh; github_pat_ fine-grained.
names=(hq-key pem-private-key github-token github-pat aws-access-key-id sk-key google-api-key jwk-private-d)
res=(
  'uhq_[A-Za-z0-9]{6,}_[A-Za-z0-9]{16,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'AKIA[0-9A-Z]{16}'
  'sk-[A-Za-z0-9]{20,}'
  'AIza[0-9A-Za-z_-]{30,}'
  "$jwk"
)

base=
if [ $# = 1 ]; then
  case $1 in -*) setup "BASE '$1' looks like an option, not a commit" ;; esac
  base=$(git rev-parse --verify --quiet "$1^{commit}") || setup "BASE '$1' is not a commit in this repository (fetch it first)"
  # A shallow commit inside the range stands in for history that is not here, and its diff would read as the whole
  # tree's; CI's default checkout is one commit deep.
  revs=$(git rev-list "$base..HEAD") || setup "can't list the commits in $1..HEAD"
  shallow=$(git rev-parse --git-path shallow)
  if [ -s "$shallow" ] && command grep -qFxf "$shallow" <<<"$revs"; then
    setup "the history is shallow inside $1..HEAD: fetch it whole (actions/checkout fetch-depth: 0) and rerun"
  fi
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/scan-secrets.XXXXXX") || setup "can't create a scratch directory"
trap 'rm -rf "$work"' EXIT
: > "$work/hits"

# The tree: grep -Z ends each file name with a NUL, so a name holding a colon or a newline comes through whole, and
# only the line number is kept from what follows it. xargs runs grep the program, never a shell function.
for i in "${!res[@]}"; do
  while IFS= read -r -d '' file && IFS= read -r rest; do
    printf '  %s:%s: %s\n' "$file" "${rest%%:*}" "${names[$i]}" >> "$work/hits"
  done < <(git ls-files -z | xargs -0 -r grep -HInZE -e "${res[$i]}" -- 2>/dev/null)
done

# The range: each line a commit adds, as "<log line> TAB <commit> TAB <file> TAB <line in the new file>", from the
# hunk headers and their counts (git quotes a path holding a tab). A content line is told from a file header by the
# hunk's remaining counts, so an added line reading "++ b/x" (shown as "+++ b/x") stays content, and an empty line
# is context (diff.suppressBlankEmpty prints one so). A merge is read as its diff against its first parent.
if [ -n "$base" ]; then
  git log -p --no-color --no-ext-diff --no-textconv --no-renames --diff-merges=first-parent \
    --src-prefix=a/ --dst-prefix=b/ --format='commit %H' "$base..HEAD" > "$work/log" || setup "git log failed on $1..HEAD"
  awk 'BEGIN { OFS = "\t" }
    old <= 0 && new <= 0 && /^commit [0-9a-f]+$/ { sha = substr($2, 1, 12); next }
    old <= 0 && new <= 0 && /^\+\+\+ / {
      path = substr($0, 5)
      if (path ~ /^b\//) path = substr(path, 3); else if (path ~ /^"b\//) path = "\"" substr(path, 4)
      next
    }
    old <= 0 && new <= 0 && /^@@ / {
      k = split($2, o, ","); old = (k > 1) ? o[2] + 0 : 1
      k = split($3, w, ","); line = substr(w[1], 2) + 0; new = (k > 1) ? w[2] + 0 : 1
      next
    }
    old > 0 || new > 0 {
      c = substr($0, 1, 1)
      if (c == "+") { print NR, sha, path, line; line++; new-- }
      else if (c == "-") old--
      else if (c == " " || $0 == "") { line++; old--; new-- }
    }' "$work/log" > "$work/added"
  for i in "${!res[@]}"; do
    command grep -anE -e "${res[$i]}" "$work/log" | cut -d: -f1 > "$work/at"
    [ -s "$work/at" ] || continue
    awk -F '\t' -v name="${names[$i]}" 'FILENAME == ARGV[1] { hit[$1] = 1; next } $1 in hit { print "  commit " $2 " " $3 ":" $4 ": " name }' \
      "$work/at" "$work/added" >> "$work/hits"
  done
fi

if [ -s "$work/hits" ]; then
  {
    echo "scan-secrets: credential-shaped text at these places (file:line: pattern; never the text itself):"
    sort -u "$work/hits"
  } >&2
  exit 1
fi
if [ -n "$base" ]; then echo "scan-secrets: clean (the tracked files, and every line the commits since $base add)"
else echo "scan-secrets: clean"; fi
