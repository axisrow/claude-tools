#!/usr/bin/env bash
# subissue.sh — driver for splitting a GitHub epic into native sub-issues.
#
# The "app" this skill drives is the GitHub Issues API via `gh` (REST for
# create/label/comment, GraphQL for the native parent/child sub-issue link).
# These three subcommands are exactly the calls debugged in the originating
# session; `create` chains issue-create → node-id lookup → addSubIssue.
#
# Usage:
#   subissue.sh probe   <OWNER> <REPO> <EPIC_NUMBER>
#       Read-only. Confirms the repo supports native sub-issues and the
#       addSubIssue mutation is in schema. Prints epic node-id + current
#       sub-issue count. Run this FIRST — no native-subissue support means
#       you must fall back to a checklist in the epic body.
#
#   subissue.sh node    <OWNER> <REPO> <ISSUE_NUMBER>
#       Read-only. Prints the GraphQL node-id of one issue.
#
#   subissue.sh create  <OWNER> <REPO> <PARENT_NODE_ID> <LABEL> <TITLE> <BODY_FILE> [--dry-run]
#       Creates an issue (with LABEL), then links it under PARENT_NODE_ID as a
#       native sub-issue. Prints "#<num> [LABEL] TITLE". --dry-run validates
#       inputs (label exists, body file readable, parent id non-empty) and
#       prints what WOULD be created, without touching the tracker.
#
#   subissue.sh count   <OWNER> <REPO> <EPIC_NUMBER>
#       Read-only. Prints the native sub-issue count for an epic (verification).
#
# Requires: gh (authenticated), jq is NOT needed (uses gh --jq).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

node_id() {
  local owner="$1" repo="$2" num="$3"
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){id}}}' \
    -F o="$owner" -F r="$repo" -F n="$num" --jq '.data.repository.issue.id'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  probe)
    owner="${1:?owner}" ; repo="${2:?repo}" ; epic="${3:?epic number}"
    # 1. addSubIssue mutation present in schema?
    has=$(gh api graphql -f query='query{__type(name:"Mutation"){fields{name}}}' \
            --jq '[.data.__type.fields[].name] | index("addSubIssue") // "MISSING"')
    [ "$has" = "MISSING" ] && die "addSubIssue mutation NOT in GraphQL schema — native sub-issues unavailable; fall back to a checklist in the epic body."
    # 2. epic readable + node-id + current count
    out=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){id subIssues{totalCount}}}}' \
            -F o="$owner" -F r="$repo" -F n="$epic" \
            --jq '"\(.data.repository.issue.id)\t\(.data.repository.issue.subIssues.totalCount)"')
    id="${out%%	*}" ; cnt="${out##*	}"
    echo "native_subissues=SUPPORTED"
    echo "epic_node_id=$id"
    echo "current_subissue_count=$cnt"
    ;;
  node)
    owner="${1:?owner}" ; repo="${2:?repo}" ; num="${3:?issue number}"
    node_id "$owner" "$repo" "$num"
    ;;
  create)
    owner="${1:?owner}" ; repo="${2:?repo}" ; parent="${3:?parent node id}"
    label="${4:?label}" ; title="${5:?title}" ; body="${6:?body file}"
    dry="${7:-}"
    [ -r "$body" ] || die "body file not readable: $body"
    [ -n "$parent" ] || die "empty parent node id"
    if [ "$dry" = "--dry-run" ]; then
      # --limit 500: gh defaults to 30 labels, so repos with more labels give
      # false "does not exist" on anything created late in the alphabet/order.
      gh label list --repo "$owner/$repo" --limit 500 --json name --jq '.[].name' | grep -qx "$label" \
        || die "label '$label' does not exist in $owner/$repo (create it first)"
      echo "DRY-RUN: would create issue in $owner/$repo titled \"$title\" with label '$label', body $(wc -l <"$body") lines, then addSubIssue under $parent"
      exit 0
    fi
    url=$(gh issue create --repo "$owner/$repo" --title "$title" --body-file "$body" --label "$label")
    num=$(basename "$url")
    child=$(node_id "$owner" "$repo" "$num")
    gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){subIssue{number}}}' \
      -F p="$parent" -F c="$child" --jq '.data.addSubIssue.subIssue.number' >/dev/null
    echo "#$num  [$label]  $title"
    ;;
  count)
    owner="${1:?owner}" ; repo="${2:?repo}" ; epic="${3:?epic number}"
    gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){subIssues{totalCount}}}}' \
      -F o="$owner" -F r="$repo" -F n="$epic" --jq '.data.repository.issue.subIssues.totalCount'
    ;;
  *)
    die "unknown command '$cmd' — use: probe | node | create | count"
    ;;
esac
