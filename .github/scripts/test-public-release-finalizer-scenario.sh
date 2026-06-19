#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  test-public-release-finalizer-scenario.sh run

Environment:
  CIRCLEFIN_API_TOKEN      Token for the public repository.
USAGE
}

PHASE="${1:-}"
if [[ -z "${PHASE}" ]]; then
  usage
  exit 1
fi

PUBLIC_REPO="${PUBLIC_REPO:-circlefin/arc-node}"
PUBLIC_TOKEN="${CIRCLEFIN_API_TOKEN:?missing CIRCLEFIN_API_TOKEN}"
PUBLIC_MAIN_BRANCH="${PUBLIC_MAIN_BRANCH:-test-main}"
PUBLIC_FINALIZER_PR="${PUBLIC_FINALIZER_PR:-172}"
PUBLIC_RELEASE_PR="${PUBLIC_RELEASE_PR:-171}"
PUBLIC_FINALIZER_HEAD="${PUBLIC_FINALIZER_HEAD:-chore-public-release-finalizer-test}"
PUBLIC_RELEASE_HEAD="${PUBLIC_RELEASE_HEAD:-sync/copybara-export-test-main-test-v0_8_0}"
PUBLIC_RELEASE_LABEL="${PUBLIC_RELEASE_LABEL:-release}"
EXPECTED_RELEASE_BRANCH="${EXPECTED_RELEASE_BRANCH:-test-release/0.8}"
EXPECTED_RELEASE_TAG="${EXPECTED_RELEASE_TAG:-test/v0.8.0}"
SCENARIO_MARKER="[test-public-release-finalizer-scenario]"

gh_public() {
  GH_TOKEN="${PUBLIC_TOKEN}" gh "$@"
}

die() {
  echo "::error::$*" >&2
  exit 1
}

note() {
  echo "$*" >&2
}

assert_test_only_config() {
  [[ "${PUBLIC_REPO}" == "circlefin/arc-node" ]] || die "Unexpected public repo: ${PUBLIC_REPO}"
  [[ "${PUBLIC_MAIN_BRANCH}" == "test-main" ]] || die "Refusing to touch non-test public main branch: ${PUBLIC_MAIN_BRANCH}"
  [[ "${EXPECTED_RELEASE_BRANCH}" == test-release/* ]] || die "Release branch must use test-release/: ${EXPECTED_RELEASE_BRANCH}"
  [[ "${EXPECTED_RELEASE_BRANCH}" != release/* ]] || die "Refusing production release branch: ${EXPECTED_RELEASE_BRANCH}"
  [[ "${EXPECTED_RELEASE_TAG}" == test/v* ]] || die "Release tag must use test/v: ${EXPECTED_RELEASE_TAG}"
  [[ "${EXPECTED_RELEASE_TAG}" != v* ]] || die "Refusing production release tag: ${EXPECTED_RELEASE_TAG}"
}

snapshot_production_refs() {
  local output="$1"

  {
    gh_public api "repos/${PUBLIC_REPO}/git/ref/heads/main" \
      --jq '"refs/heads/main " + .object.sha' 2>/dev/null || true
    gh_public api "repos/${PUBLIC_REPO}/git/matching-refs/heads/release" \
      --jq '.[] | .ref + " " + .object.sha' 2>/dev/null || true
    gh_public api "repos/${PUBLIC_REPO}/git/matching-refs/tags/v" \
      --jq '.[] | .ref + " " + .object.sha' 2>/dev/null || true
  } | sort > "${output}"
}

assert_production_refs_unchanged() {
  local before="$1"
  local after="$2"

  if ! diff -u "${before}" "${after}"; then
    die "Production refs changed; refusing to continue"
  fi
}

pr_json() {
  local pr="$1"
  gh_public api "repos/${PUBLIC_REPO}/pulls/${pr}"
}

assert_pr_shape() {
  local pr="$1"
  local expected_head="$2"
  local json base head

  json="$(pr_json "${pr}")"
  base="$(jq -r '.base.ref' <<< "${json}")"
  head="$(jq -r '.head.ref' <<< "${json}")"

  [[ "${base}" == "${PUBLIC_MAIN_BRANCH}" ]] || die "PR #${pr} base must be ${PUBLIC_MAIN_BRANCH}, got ${base}"
  [[ "${head}" == "${expected_head}" ]] || die "PR #${pr} head must be ${expected_head}, got ${head}"
}

assert_release_pr_metadata() {
  local json body

  json="$(pr_json "${PUBLIC_RELEASE_PR}")"
  body="$(jq -r '.body // ""' <<< "${json}")"
  grep -Fxq "Release tag: ${EXPECTED_RELEASE_TAG}" <<< "${body}" \
    || die "Public release PR body must declare ${EXPECTED_RELEASE_TAG}"
  grep -Fxq "Release branch: ${EXPECTED_RELEASE_BRANCH}" <<< "${body}" \
    || die "Public release PR body must declare ${EXPECTED_RELEASE_BRANCH}"
  grep -Fxq "Release kind: minor" <<< "${body}" \
    || die "Public release PR body must declare Release kind: minor"
}

ref_exists() {
  local ref="$1"
  gh_public api "repos/${PUBLIC_REPO}/git/ref/${ref}" >/dev/null 2>&1
}

ref_target_sha() {
  local ref="$1"
  local json object_type object_sha

  json="$(gh_public api "repos/${PUBLIC_REPO}/git/ref/${ref}")"
  object_type="$(jq -r '.object.type' <<< "${json}")"
  object_sha="$(jq -r '.object.sha' <<< "${json}")"
  if [[ "${object_type}" == "tag" ]]; then
    gh_public api "repos/${PUBLIC_REPO}/git/tags/${object_sha}" --jq '.object.sha'
  else
    printf '%s\n' "${object_sha}"
  fi
}

assert_no_final_refs_before_release_merge() {
  local release_json merged

  release_json="$(pr_json "${PUBLIC_RELEASE_PR}")"
  merged="$(jq -r '.merged' <<< "${release_json}")"
  if [[ "${merged}" == "true" ]]; then
    return
  fi

  ref_exists "heads/${EXPECTED_RELEASE_BRANCH}" \
    && die "${EXPECTED_RELEASE_BRANCH} already exists before release PR merge"
  ref_exists "tags/${EXPECTED_RELEASE_TAG}" \
    && die "${EXPECTED_RELEASE_TAG} already exists before release PR merge"
  return 0
}

ensure_release_label() {
  if gh_public api "repos/${PUBLIC_REPO}/labels/${PUBLIC_RELEASE_LABEL}" >/dev/null 2>&1; then
    return
  fi

  note "Creating ${PUBLIC_REPO} label ${PUBLIC_RELEASE_LABEL}"
  gh_public api -X POST "repos/${PUBLIC_REPO}/labels" \
    -f name="${PUBLIC_RELEASE_LABEL}" \
    -f color=0E8A16 \
    -f description="Marks Copybara release PRs for public release finalization" \
    >/dev/null
}

pr_has_label() {
  local pr="$1"
  gh_public api "repos/${PUBLIC_REPO}/issues/${pr}/labels" \
    --jq '.[].name' \
    | grep -Fxq "${PUBLIC_RELEASE_LABEL}"
}

label_release_pr() {
  if pr_has_label "${PUBLIC_RELEASE_PR}"; then
    note "PR #${PUBLIC_RELEASE_PR} already has ${PUBLIC_RELEASE_LABEL}"
    return
  fi

  note "Adding ${PUBLIC_RELEASE_LABEL} label to PR #${PUBLIC_RELEASE_PR}"
  gh_public api -X POST "repos/${PUBLIC_REPO}/issues/${PUBLIC_RELEASE_PR}/labels" \
    -f "labels[]=${PUBLIC_RELEASE_LABEL}" \
    >/dev/null
}

wait_for_public_file() {
  local path="$1"

  for _ in {1..30}; do
    if gh_public api "repos/${PUBLIC_REPO}/contents/${path}?ref=${PUBLIC_MAIN_BRANCH}" >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  die "Timed out waiting for ${path} on ${PUBLIC_REPO}:${PUBLIC_MAIN_BRANCH}"
}

wait_for_mergeable() {
  local pr="$1"
  local mergeable

  for _ in {1..30}; do
    mergeable="$(gh_public api "repos/${PUBLIC_REPO}/pulls/${pr}" --jq '.mergeable')" || mergeable="null"
    case "${mergeable}" in
      true) return ;;
      false) die "PR #${pr} is not mergeable" ;;
      null) sleep 2 ;;
      *) sleep 2 ;;
    esac
  done

  die "Timed out waiting for PR #${pr} mergeability"
}

merge_public_pr() {
  local pr="$1"
  local description="$2"
  local json state merged merge_sha merge_json

  json="$(pr_json "${pr}")"
  state="$(jq -r '.state' <<< "${json}")"
  merged="$(jq -r '.merged' <<< "${json}")"
  merge_sha="$(jq -r '.merge_commit_sha // ""' <<< "${json}")"

  if [[ "${merged}" == "true" ]]; then
    [[ -n "${merge_sha}" ]] || die "PR #${pr} is merged but has no merge_commit_sha"
    note "PR #${pr} is already merged at ${merge_sha}"
    printf '%s\n' "${merge_sha}"
    return
  fi

  [[ "${state}" == "open" ]] || die "PR #${pr} is ${state}, not open"
  wait_for_mergeable "${pr}"

  note "Merging ${PUBLIC_REPO}#${pr} into ${PUBLIC_MAIN_BRANCH}"
  if ! merge_json="$(
    gh_public api -X PUT "repos/${PUBLIC_REPO}/pulls/${pr}/merge" \
      -f merge_method=merge \
      -f commit_title="${SCENARIO_MARKER} merge ${description} PR #${pr}" \
      -f commit_message="Automated public release finalizer scenario merge."
  )"; then
    die "Failed to merge ${PUBLIC_REPO}#${pr}"
  fi
  merge_sha="$(jq -r '.sha // ""' <<< "${merge_json}")"
  [[ -n "${merge_sha}" && "${merge_sha}" != "null" ]] || die "Merge API did not return a SHA for ${PUBLIC_REPO}#${pr}"
  printf '%s\n' "${merge_sha}"
}

wait_for_check_success() {
  local pr="$1"
  local check_name="$2"
  local head_sha json total status conclusion

  head_sha="$(gh_public api "repos/${PUBLIC_REPO}/pulls/${pr}" --jq '.head.sha')"
  for _ in {1..90}; do
    json="$(
      gh_public api -X GET "repos/${PUBLIC_REPO}/commits/${head_sha}/check-runs" \
        -f check_name="${check_name}"
    )"
    total="$(jq -r '.total_count' <<< "${json}")"
    if [[ "${total}" != "0" ]]; then
      status="$(jq -r '.check_runs | sort_by(.started_at) | last | .status' <<< "${json}")"
      conclusion="$(jq -r '.check_runs | sort_by(.started_at) | last | .conclusion // ""' <<< "${json}")"
      if [[ "${status}" == "completed" && "${conclusion}" == "success" ]]; then
        note "${check_name} passed for PR #${pr}"
        return
      fi
      if [[ "${status}" == "completed" ]]; then
        die "${check_name} concluded ${conclusion} for PR #${pr}"
      fi
    fi
    sleep 2
  done

  die "Timed out waiting for ${check_name} on PR #${pr}"
}

run_release_finalizer() {
  local mode="$1"
  local merge_sha="${2:-}"
  local json body

  json="$(pr_json "${PUBLIC_RELEASE_PR}")"
  body="$(jq -r '.body // ""' <<< "${json}")"

  RELEASE_NAMESPACE=auto \
    PR_BODY="${body}" \
    PR_BASE_REF="${PUBLIC_MAIN_BRANCH}" \
    PR_HEAD_REF="${PUBLIC_RELEASE_HEAD}" \
    MERGE_COMMIT_SHA="${merge_sha}" \
    bash .github/scripts/finalize-release.sh "${mode}"
}

wait_for_final_refs() {
  local expected_sha="$1"
  local branch_sha tag_sha

  for _ in {1..90}; do
    branch_sha="$(ref_target_sha "heads/${EXPECTED_RELEASE_BRANCH}" 2>/dev/null || true)"
    tag_sha="$(ref_target_sha "tags/${EXPECTED_RELEASE_TAG}" 2>/dev/null || true)"

    if [[ "${branch_sha}" == "${expected_sha}" && "${tag_sha}" == "${expected_sha}" ]]; then
      note "${EXPECTED_RELEASE_BRANCH} and ${EXPECTED_RELEASE_TAG} point at ${expected_sha}"
      return
    fi

    if [[ -n "${branch_sha}" && "${branch_sha}" != "${expected_sha}" ]]; then
      die "${EXPECTED_RELEASE_BRANCH} points at ${branch_sha}, expected ${expected_sha}"
    fi
    if [[ -n "${tag_sha}" && "${tag_sha}" != "${expected_sha}" ]]; then
      die "${EXPECTED_RELEASE_TAG} points at ${tag_sha}, expected ${expected_sha}"
    fi

    sleep 2
  done

  die "Timed out waiting for ${EXPECTED_RELEASE_BRANCH} and ${EXPECTED_RELEASE_TAG}"
}

run_scenario() {
  local before after finalizer_sha release_sha

  note "Checking test-only scenario configuration"
  assert_test_only_config
  before="$(mktemp)"
  after="$(mktemp)"
  note "Snapshotting production refs before scenario"
  snapshot_production_refs "${before}"

  note "Validating public finalizer PR #${PUBLIC_FINALIZER_PR}"
  assert_pr_shape "${PUBLIC_FINALIZER_PR}" "${PUBLIC_FINALIZER_HEAD}"
  note "Validating public release PR #${PUBLIC_RELEASE_PR}"
  assert_pr_shape "${PUBLIC_RELEASE_PR}" "${PUBLIC_RELEASE_HEAD}"
  assert_release_pr_metadata
  note "Checking final test refs are absent before release PR merge"
  assert_no_final_refs_before_release_merge

  finalizer_sha="$(merge_public_pr "${PUBLIC_FINALIZER_PR}" "finalizer")"
  note "Finalizer PR merge commit: ${finalizer_sha}"
  wait_for_public_file ".github/workflows/finalize-release.yaml"
  wait_for_public_file ".github/scripts/finalize-release.sh"
  wait_for_public_file ".github/scripts/test-public-release-finalizer-scenario.sh"

  ensure_release_label
  label_release_pr
  run_release_finalizer validate

  release_sha="$(merge_public_pr "${PUBLIC_RELEASE_PR}" "release")"
  note "Release PR merge commit: ${release_sha}"
  run_release_finalizer finalize "${release_sha}"
  wait_for_final_refs "${release_sha}"

  snapshot_production_refs "${after}"
  assert_production_refs_unchanged "${before}" "${after}"
}

case "${PHASE}" in
  run) run_scenario ;;
  -h|--help) usage ;;
  *) echo "Unknown phase: ${PHASE}" >&2; usage; exit 1 ;;
esac
