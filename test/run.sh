#!/usr/bin/env bash
# Test runner for kubectl-b64edit using stub kubectl/$EDITOR - no real cluster
# or shellcheck/bats dependency required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BIN="$REPO_ROOT/bin/kubectl-b64edit"
FIXTURES="$HERE/fixtures"
STUBS="$HERE/stubs"

pass=0
fail=0

log_fail() { echo "FAIL: $1"; fail=$((fail + 1)); }
log_pass() { echo "PASS: $1"; pass=$((pass + 1)); }

# Populates globals LAST_OUT, LAST_RC, LAST_CAPTURE. Run directly (not via
# command substitution) so pass/fail counters and globals reach the caller.
run_case() {
  local name="$1" fixture="$2" expected_exit="$3"
  shift 3

  local case_dir
  case_dir="$(mktemp -d)"
  LAST_CAPTURE="$case_dir/captured.json"

  LAST_OUT="$(
    env -i PATH="$STUBS:$PATH" HOME="$HOME" \
      EDITOR="$STUBS/editor" \
      STUB_KUBECTL_FIXTURE="$FIXTURES/$fixture" \
      STUB_KUBECTL_CAPTURE="$LAST_CAPTURE" \
      "$@" \
      "$BIN" --yes secret demo 2>&1
  )"
  LAST_RC=$?

  if [[ "$LAST_RC" -ne "$expected_exit" ]]; then
    log_fail "$name (exit $LAST_RC, expected $expected_exit)"
    echo "$LAST_OUT" | sed 's/^/    /'
  else
    log_pass "$name"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    log_pass "$name"
  else
    log_fail "$name (missing: $needle)"
  fi
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "$name"
  else
    log_fail "$name (got [$actual], expected [$expected])"
  fi
}

echo "== unchanged buffer: no-op, no write =="
run_case "unchanged: exit 0, no write" "secret-basic.json" 0 env STUB_EDIT_NOOP=1
if [[ -e "$LAST_CAPTURE" ]]; then
  log_fail "unchanged: expected no kubectl replace call"
else
  log_pass "unchanged: no kubectl replace call"
fi

echo "== changed value + new key: correct re-encode, others untouched =="
run_case "changed value: exit 0" "secret-basic.json" 0 env STUB_EDIT_SED='s/s3cr3tPass/newpass123/'
if [[ -e "$LAST_CAPTURE" ]]; then
  assert_eq "password re-encoded correctly" \
    "$(jq -r '.data.password' "$LAST_CAPTURE" | base64 -d)" "newpass123"
  assert_eq "username byte-identical to original" \
    "$(jq -r '.data.username' "$LAST_CAPTURE")" \
    "$(jq -r '.data.username' "$FIXTURES/secret-basic.json")"
  assert_eq "binary blob byte-identical to original" \
    "$(jq -r '.data.binaryblob' "$LAST_CAPTURE")" \
    "$(jq -r '.data.binaryblob' "$FIXTURES/secret-basic.json")"
  assert_eq "resourceVersion preserved" \
    "$(jq -r '.metadata.resourceVersion' "$LAST_CAPTURE")" "12345"
else
  log_fail "changed value: expected kubectl replace call, got none"
fi

echo "== immutable secret: refuse to edit =="
run_case "immutable secret rejected" "secret-immutable.json" 3 env STUB_EDIT_NOOP=1

echo "== 409 conflict from server: surfaced, not swallowed =="
run_case "conflict surfaced as exit 5" "secret-basic.json" 5 \
  env STUB_EDIT_SED='s/s3cr3tPass/newpass123/' STUB_KUBECTL_CONFLICT=1
assert_contains "conflict message mentions resourceVersion/conflict" "$LAST_OUT" "onflict"

echo "== invalid YAML on first save: retried, then applied =="
run_case "corrupt-then-fix retried to success" "secret-basic.json" 0 \
  env STUB_EDIT_CORRUPT_ONCE=1 STUB_EDIT_SED='s/s3cr3tPass/newpass123/'
if [[ -e "$LAST_CAPTURE" ]]; then
  log_pass "corrupt-then-fix eventually wrote"
else
  log_fail "corrupt-then-fix eventually wrote"
fi

echo "== Helm-managed resource: warns before applying =="
run_case "gitops warning printed" "secret-helm.json" 0 env STUB_EDIT_SED='s/superse/otherse/'
assert_contains "warns about Helm management" "$LAST_OUT" "GitOps/controller-managed"

echo "== --view mode: read-only, no kubectl replace, no confirmation =="
case_dir="$(mktemp -d)"
capture="$case_dir/captured.json"
out="$(
  env -i PATH="$STUBS:$PATH" HOME="$HOME" \
    STUB_KUBECTL_FIXTURE="$FIXTURES/secret-basic.json" \
    STUB_KUBECTL_CAPTURE="$capture" \
    "$BIN" --view secret demo 2>&1
)"
rc=$?
assert_eq "--view exits 0" "$rc" "0"
assert_contains "--view shows decoded value" "$out" "admin"
if [[ -e "$capture" ]]; then
  log_fail "--view must not call kubectl replace"
else
  log_pass "--view must not call kubectl replace"
fi

echo
echo "== ConfigMap binaryData handling =="
run_case "configmap noop" "configmap-basic.json" 0 env STUB_EDIT_NOOP=1
if [[ -e "$LAST_CAPTURE" ]]; then
  log_fail "configmap noop: expected no write"
else
  log_pass "configmap noop: expected no write"
fi

echo
echo "---------------------------------------------"
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
