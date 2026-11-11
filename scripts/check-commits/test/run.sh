#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$TEST_DIR/../check-commits.sh"
LEGACY="$TEST_DIR/original-check-commits.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PATH="$TEST_DIR:$PATH" REPO=test/repo PR_NUMBER=1 HEAD_SHA=head GH_TOKEN=test
export FIXTURE="$work/fixture"
mkdir -p "$FIXTURE" "$work/repo"
cd "$work/repo"
passed=0
reset_fixture() {
  rm -rf .changeset apps examples packages package.json
  mkdir -p .changeset apps/a examples/e packages/p
  printf '{"ignore":["@portabletext/ignored"]}\n' > .changeset/config.json
  printf '{"name":"@portabletext/root","private":true}\n' > package.json
  printf '{"name":"@portabletext/app","private":true}\n' > apps/a/package.json
  printf '{"name":"@portabletext/example","private":true}\n' > examples/e/package.json
  printf '{"name":"@portabletext/private","private":true}\n' > packages/p/package.json
  echo '[]' > "$FIXTURE/commits.json"
  echo '[]' > "$FIXTURE/pr-files.json"
  : > "$FIXTURE/calls"
}
commit() {
  local subject=$1 status=${2:-none} author=${3:-human} parents=${4:-1} path=${5:-.changeset/change.md}
  local sha
  sha=$(jq -r 'length + 1 | "abcdef" + tostring' "$FIXTURE/commits.json")
  jq --arg sha "$sha" --arg subject "$subject" --arg author "$author" --argjson parents "$parents" \
    '. + [{sha:$sha,commit:{message:$subject},author:{login:$author},parents:[range($parents) | {sha:tostring}]}]' \
    "$FIXTURE/commits.json" > "$FIXTURE/next.json"
  mv "$FIXTURE/next.json" "$FIXTURE/commits.json"
  jq -n --arg status "$status" --arg path "$path" '{files: (if $status == "none" then [] else [{status:$status,filename:$path}] end)}' > "$FIXTURE/$sha.json"
  if [[ "$status" == added && "$path" == .changeset/*.md && "$path" != .changeset/README.md ]]; then
    jq --arg path "$path" '. + [{status:"added",filename:$path}]' "$FIXTURE/pr-files.json" > "$FIXTURE/next.json"
    mv "$FIXTURE/next.json" "$FIXTURE/pr-files.json"
    printf '%s\n' '---' '"test": patch' '---' '' "$subject" > "$FIXTURE/content"
  fi
}
check() {
  local expected=$1 label=$2 script=${3:-$SCRIPT} message=${4:-} result=0
  bash "$script" > "$FIXTURE/output" 2>&1 || result=$?
  if { [[ "$expected" == pass ]] && ((result != 0)); } || { [[ "$expected" == fail ]] && ((result == 0)); }; then
    echo "FAIL: $label ($expected, exit $result)"
    cat "$FIXTURE/output"
    exit 1
  fi
  if [[ -n "$message" ]] && ! grep -qF "$message" "$FIXTURE/output"; then
    echo "FAIL: $label (missing diagnostic: $message)"
    cat "$FIXTURE/output"
    exit 1
  fi
  passed=$((passed + 1))
  echo "PASS: $label"
}
for type in chore refactor test docs; do
  reset_fixture
  commit "$type: update" added
  check pass "legacy accepts $type changeset addition (red)" "$LEGACY"
  check fail "shared rejects $type changeset addition (green)" "$SCRIPT" 'A commit that adds a changeset is fix: or feat:.'
  grep -qF 'abcdef1' "$FIXTURE/output"
done
for status in modified renamed; do
  reset_fixture
  commit 'docs: reword' "$status"
  check pass "rule 4 allows $status"
done
for exemption in bot merge revert; do
  reset_fixture
  case "$exemption" in
    bot) commit 'chore(deps): update' added 'ecoscript[bot]' ;;
    merge) commit 'Merge main' added human 2 ;;
    revert) commit 'Revert "feat: update"' added ;;
  esac
  check pass "rule 4 allows $exemption"
done
for subject in 'feat!: update' 'fix(scope): update'; do
  reset_fixture
  commit "$subject" added
  check pass "rule 4 allows $subject"
done
for prefix in fixup squash amend; do
  reset_fixture
  commit "$prefix! fix: update"
  check fail "rule 1 rejects $prefix" "$SCRIPT" 'Found unsquashed'
  check fail "legacy rule 1 rejects $prefix" "$LEGACY" 'Found unsquashed'
done
reset_fixture
commit 'fix: update' added
check pass 'rules 1-3 pass'
check pass 'legacy rules 1-3 pass' "$LEGACY"
printf '\r\nwrong subject\r\n' > "$FIXTURE/content"
check fail 'rule 2 rejects wrong subject' "$SCRIPT" 'not a commit subject'
check fail 'legacy rule 2 rejects wrong subject' "$LEGACY" 'not a commit subject'
reset_fixture
commit 'feat: update'
check fail 'rule 3 rejects missing changeset' "$SCRIPT" 'These fix/feat commits ship no changeset'
check fail 'legacy rule 3 rejects missing changeset' "$LEGACY" 'These fix/feat commits ship no changeset'
for scope in ignored root app example private; do
  reset_fixture
  commit "fix($scope): update"
  check pass "monorepo unreleased scope $scope"
done
reset_fixture
rm -rf apps examples packages .changeset
commit 'feat(root): update'
check pass 'single private root without changeset config'
reset_fixture
rm -rf apps examples packages
printf '{}\n' > .changeset/config.json
printf '{"name":"public-root"}\n' > package.json
commit 'fix(public-root): update'
check fail 'single public root without ignore is releasable' "$SCRIPT" 'ship no changeset'
for path in package.json packages/new/package.json; do
  reset_fixture
  commit 'feat: new package' added human 1 "$path"
  check pass "new package at $path"
done
reset_fixture
commit 'fix: dependency update' none 'renovate[bot]'
commit 'chore(deps): changeset for dependency update' added 'ecoscript[bot]'
check pass 'Renovate follow-up exemption'
[[ $(grep -c '^repos/test/repo/commits/abcdef' "$FIXTURE/calls") == 2 ]]
echo 'PASS: each commit file list fetched once'
reset_fixture
commit 'chore: readme' added human 1 .changeset/README.md
commit 'chore: nested' added human 1 .changeset/pre/change.md
check pass 'README and nested changesets excluded'
printf 'Passed %s checks.\n' "$passed"
