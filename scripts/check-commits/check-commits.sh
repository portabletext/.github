#!/usr/bin/env bash
set -euo pipefail

commits=$(gh api "repos/$REPO/pulls/$PR_NUMBER/commits" --paginate | jq -s 'add')
offenders=$(jq -r '.[] | select(.commit.message | split("\n")[0] | test("^(fixup|squash|amend)!")) | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"' <<< "$commits")
if [ -n "$offenders" ]; then
  echo "Found unsquashed fixup/squash/amend commits:"
  echo "$offenders"
  echo "Squash them with 'git rebase -i --autosquash' before merge."
  exit 1
fi

(
  changesets=$(gh api "repos/$REPO/pulls/$PR_NUMBER/files" --paginate \
    --jq '.[] | select(.status == "added") | .filename | select(test("^\\.changeset/[^/]+\\.md$")) | select(. != ".changeset/README.md")')

  if [ -z "$changesets" ]; then
    echo "No changesets added."
    exit 0
  fi

  subjects=$(jq -r '.[] | .commit.message | split("\n")[0]' <<< "$commits")

  failed=0
  while IFS= read -r changeset; do
    first_line=$(gh api "repos/$REPO/contents/$changeset?ref=$HEAD_SHA" \
      -H "Accept: application/vnd.github.raw" \
      | tr -d '\r' \
      | awk 'NR == 1 && $0 == "---" { in_frontmatter = 1; next }
             in_frontmatter { if ($0 == "---") in_frontmatter = 0; next }
             NF && !found { print; found = 1 }')

    if ! grep -qxF -- "$first_line" <<< "$subjects"; then
      echo "$changeset opens with a line that is not a commit subject in this PR:"
      echo "  $first_line"
      failed=1
    fi
  done <<< "$changesets"

  if [ "$failed" -eq 1 ]; then
    echo "Commit subjects in this PR:"
    sed 's/^/  /' <<< "$subjects"
    echo "The first line of a changeset repeats a commit subject verbatim."
    exit 1
  fi

)

# Scopes that never release: packages changesets ignores and private
# packages, named with or without the `@portabletext/` prefix.
unreleased=$( {
  if [ -f .changeset/config.json ]; then
    jq -r '.ignore[]?' .changeset/config.json
  fi
  shopt -s nullglob
  for manifest in package.json apps/*/package.json examples/*/package.json packages/*/package.json; do
    if [ -f "$manifest" ]; then
      jq -r 'select(.private == true) | .name' "$manifest"
    fi
  done
} | sed 's|^@portabletext/||' | sort -u)

# Populate the cache only when a rule needs files, in the parent shell.
declare -A commit_files
fetch_commit_files() {
  local sha=$1
  if [[ ! -v commit_files[$sha] ]]; then
    if ! commit_files["$sha"]=$(gh api "repos/$REPO/commits/$sha" --paginate --jq '(.files // [])[] | "\(.status) \(.filename)"'); then
      echo "Failed to fetch files for commit $sha" >&2
      exit 1
    fi
  fi
}

ships_changeset() {
  grep -E '^(added|modified|renamed) \.changeset/[^/]+\.md$' <<< "$1" | grep -qv ' \.changeset/README\.md$'
}

offenders=""
count=$(jq length <<< "$commits")
for ((i = 0; i < count; i++)); do
  sha=$(jq -r ".[$i].sha" <<< "$commits")
  subject=$(jq -r ".[$i].commit.message | split(\"\n\")[0]" <<< "$commits")
  author=$(jq -r ".[$i].author.login // \"\"" <<< "$commits")

  if ! [[ "$subject" =~ ^(fix|feat)(\(([^\)]*)\))?!?: ]]; then
    continue
  fi
  scope=${BASH_REMATCH[3]}
  if [ -n "$scope" ] && grep -qxF -- "$scope" <<< "$unreleased"; then
    continue
  fi

  fetch_commit_files "$sha"
  files=${commit_files[$sha]}
  if ships_changeset "$files"; then
    continue
  fi

  # A new package's 1.0.0 is published by hand, so the commit that
  # introduces it has no changeset.
  if grep -qE '^added (packages/[^/]+/)?package\.json$' <<< "$files"; then
    continue
  fi

  # Renovate commits get their changeset from a follow-up bot commit.
  if [ "$author" = "renovate[bot]" ]; then
    followed=0
    for ((j = i + 1; j < count; j++)); do
      if [ "$(jq -r ".[$j].author.login // \"\"" <<< "$commits")" = "ecoscript[bot]" ]; then
        followup_sha=$(jq -r ".[$j].sha" <<< "$commits")
        fetch_commit_files "$followup_sha"
        if ships_changeset "${commit_files[$followup_sha]}"; then
          followed=1
          break
        fi
      fi
    done
    if [ "$followed" -eq 1 ]; then
      continue
    fi
  fi

  offenders+="  ${sha:0:7} $subject"$'\n'
done

if [ -n "$offenders" ]; then
  echo "These fix/feat commits ship no changeset:"
  printf '%s' "$offenders"
  echo "Each fix/feat commit ships its own changeset in the same commit."
  echo "Retype a commit without a releasable change as refactor:, chore:, test: or docs:."
  exit 1
fi

# Only additions need a release subject; edits and pre-mode renames can be chores.
offenders=""
for ((i = 0; i < count; i++)); do
  sha=$(jq -r ".[$i].sha" <<< "$commits")
  subject=$(jq -r ".[$i].commit.message | split(\"\n\")[0]" <<< "$commits")
  author=$(jq -r ".[$i].author.login // \"\"" <<< "$commits")
  parents=$(jq ".[$i].parents | length" <<< "$commits")
  if [[ "$subject" =~ ^(fix|feat)(\(([^\)]*)\))?!?: ]] ||
    [[ "$author" == *'[bot]' ]] || [ "$parents" -gt 1 ] ||
    [[ "$subject" == 'Revert "'* ]]; then
    continue
  fi
  fetch_commit_files "$sha"
  if grep -E '^added \.changeset/[^/]+\.md$' <<< "${commit_files[$sha]}" | grep -qv ' \.changeset/README\.md$'; then
    offenders+="  ${sha:0:7} $subject"$'\n'
  fi
done

if [ -n "$offenders" ]; then
  echo "These commits add a changeset without a fix/feat subject:"
  printf '%s' "$offenders"
  echo "A commit that adds a changeset is fix: or feat:. Retype it, or move the changeset into the fix/feat commit it describes."
  exit 1
fi
