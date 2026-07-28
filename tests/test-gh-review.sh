#!/usr/bin/env bash
# Guard tests for ~/bin/gh-review. Exit 3 == blocked by the wrapper's guards;
# exit 2 (usage) and 4 (no token) are the wrapper's OWN error exits and are
# scored separately as WRAPPER-ERROR - they are emphatically not "the guard
# let it through". Anything else == the guard passed the call to gh (which
# may then 404, that's fine - we are testing the guard, not the API).
#
# Tests the gh-review sitting next to this file, not whatever is installed on
# PATH - otherwise a green run says nothing about the version being committed.
#
# Network-touching by design: the "allowed" cases must reach gh to prove the
# guard let them past, so they need GH_REVIEWER_TOKEN in the pa store. They
# aim at PR 999999 / bogus node ids, so nothing is ever actually posted.
GH_REVIEW="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gh-review"
R=strangeparts/router-config
pass=0; fail=0

# Preflight. Without a token every MUST ALLOW case exits 4 before reaching gh,
# and a suite that scored that as "allowed" would report a perfect run while
# proving nothing - the exact failure this suite exists to prevent.
pa-secrets get GH_REVIEWER_TOKEN >/dev/null 2>&1 || {
  echo "GH_REVIEWER_TOKEN missing from the pa store - the MUST ALLOW cases cannot prove anything." >&2
  echo "Add it (in a real Terminal): pa-secrets add GH_REVIEWER_TOKEN" >&2
  exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s' 'mutation { mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }' > "$TMP/merge.graphql"
printf '%s' '{"query":"mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }"}' > "$TMP/merge.json"
# A realistic review payload: prose *about* code. It mentions a mutation and
# contains `name(`, which is exactly what a round of review on this wrapper
# looks like - and is how the round-1 review of this PR was actually posted.
printf '%s' '{"event":"COMMENT","body":"refusing a merge mutation - the check() helper reads the wrong exit code"}' > "$TMP/review.json"

check() {
  local want="$1" desc="$2"; shift 2
  # stdin from /dev/null so a case that legitimately reaches `gh` with
  # `--input -` returns instead of blocking on a terminal read.
  "$GH_REVIEW" "$@" >/dev/null 2>&1 </dev/null
  local rc=$?
  local got
  case $rc in
    3)       got="BLOCKED" ;;
    2|4)     got="WRAPPER-ERROR" ;;   # usage / missing token - never a pass
    127)     got="WRAPPER-ERROR" ;;   # `exec gh` failed - gh not on PATH
    *)       got="allowed" ;;
  esac
  if [ "$got" = "$want" ]; then
    printf '  ok    %-9s %s\n' "$got" "$desc"; pass=$((pass+1))
  else
    printf '  FAIL  got=%-13s want=%-9s %s\n' "$got" "$want" "$desc"; fail=$((fail+1))
  fi
}

# Positive control. The preflight proves a token EXISTS; it does not prove
# any call gets past the wrapper's final `exec gh`. Without this, a wrapper
# broken in a way that never reaches gh scores a perfect allow half - the
# same class of vacuity as the tokenless run, one step further down. A stub
# gh that exits 42 makes "reached gh" an observable, distinct from "did not
# exit 3".
STUB="$TMP/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 42\n' > "$STUB/gh"
chmod +x "$STUB/gh"

reaches_gh() {
  local desc="$1"; shift
  PATH="$STUB:$PATH" "$GH_REVIEW" "$@" >/dev/null 2>&1 </dev/null
  local rc=$?
  if [ "$rc" -eq 42 ]; then
    printf '  ok    %-11s %s\n' "reached-gh" "$desc"; pass=$((pass+1))
  else
    printf '  FAIL  got=exit-%-5s want=reached-gh  %s\n' "$rc" "$desc"; fail=$((fail+1))
  fi
}

echo "POSITIVE CONTROL - allow-side calls really reach gh:"
reaches_gh "api user"                       api user
reaches_gh "POST pulls/N/reviews"           api -X POST "repos/$R/pulls/999999/reviews" -f event=APPROVE -f body=x
reaches_gh "graphql resolveReviewThread"    api graphql -f 'query=mutation { resolveReviewThread(input:{threadId:"x"}) { thread { isResolved } } }'
reaches_gh "pr review --approve"            pr review 999999 --repo "$R" --approve --body 'LGTM'
reaches_gh "REST POST --input <file>"       api "repos/$R/pulls/999999/reviews" --method POST --input "$TMP/review.json"

echo "MUST BLOCK - subcommands:"
check BLOCKED "pr merge"                    pr merge 5 --repo "$R"
check BLOCKED "pr close"                    pr close 5 --repo "$R"
check BLOCKED "pr create"                   pr create --repo "$R" --title x --body y
check BLOCKED "issue close"                 issue close 5 --repo "$R"
check BLOCKED "repo delete"                 repo delete "$R"
check BLOCKED "workflow run"                workflow run deploy.yml --repo "$R"
check BLOCKED "run cancel"                  run cancel 123 --repo "$R"
check BLOCKED "run rerun"                   run rerun 123 --repo "$R"
check BLOCKED "run delete"                  run delete 123 --repo "$R"
check BLOCKED "cache delete"                cache delete --all --repo "$R"

echo "MUST BLOCK - REST, every -X/--method spelling:"
check BLOCKED "REST merge endpoint"         api -X PUT "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, lowercase -X"    api -X put "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, glued -XPUT"     api -XPUT "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, -X=PUT"          api -X=PUT "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, --method=PUT"    api --method=PUT "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, --method PUT"    api --method PUT "repos/$R/pulls/5/merge"

echo "MUST BLOCK - REST, path detection can't be knocked off:"
# -i is --include (a boolean); treating it as value-taking swallows the path,
# and an empty path matched no deny pattern under the old deny-list shape.
check BLOCKED "merge behind -i (--include)" api -X PUT -i "repos/$R/pulls/5/merge"
check BLOCKED "merge behind --include"      api -X PUT --include "repos/$R/pulls/5/merge"
# -p/--preview DOES take a value; if it's missing from the skip list its value
# is captured as the path and the real path never is.
check BLOCKED "merge behind -p <value>"     api -X PUT -p x "repos/$R/pulls/5/merge"
check BLOCKED "merge with ?query string"    api -X PUT "repos/$R/pulls/5/merge?x=/reviews"

echo "MUST BLOCK - REST writes outside the review lane:"
check BLOCKED "POST git/refs (push)"        api -X POST "repos/$R/git/refs" -f ref=refs/heads/x
check BLOCKED "POST git/commits"            api -X POST "repos/$R/git/commits" -f message=x
check BLOCKED "PUT contents (edit file)"    api -X PUT "repos/$R/contents/README.md" -f message=x
check BLOCKED "DELETE branch protection"    api -X DELETE "repos/$R/branches/main/protection"
check BLOCKED "PUT collaborators"           api -X PUT "repos/$R/collaborators/someone"
check BLOCKED "PATCH pr state=closed"       api -X PATCH "repos/$R/pulls/5" -f state=closed
check BLOCKED "POST pulls (create a PR)"    api -X POST "repos/$R/pulls" -f title=x
check BLOCKED "DELETE the repo"             api -X DELETE "repos/$R"

echo "MUST BLOCK - graphql, every way to supply a query:"
check BLOCKED "graphql mergePullRequest"    api graphql -f 'query=mutation { mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "graphql glued --field="      api graphql --field='query=mutation { mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "graphql -F query=@file"      api graphql -F "query=@$TMP/merge.graphql"
check BLOCKED "graphql --input <file>"      api graphql -X POST --input "$TMP/merge.json"
check BLOCKED "graphql --input - (stdin)"   api graphql -X POST --input -
check BLOCKED "graphql createCommitOnBranch" api graphql -f 'query=mutation { createCommitOnBranch(input:{}) { commit { oid } } }'
check BLOCKED "graphql deleteRef"           api graphql -f 'query=mutation { deleteRef(input:{refId:"x"}) { clientMutationId } }'
check BLOCKED "graphql mergeBranch"         api graphql -f 'query=mutation { mergeBranch(input:{}) { mergeCommit { oid } } }'
check BLOCKED "graphql markPRReadyForReview" api graphql -f 'query=mutation { markPullRequestReadyForReview(input:{}) { clientMutationId } }'
check BLOCKED "graphql unknown mutation"    api graphql -f 'query=mutation { someMutationNobodyAllowListed(input:{}) { id } }'
# Literal-stripping desync. The `\\` is an escaped backslash, so the quote
# after it really does end the string - a merge following it is TOP-LEVEL,
# not inside a literal. If the escaped-backslash term is ever dropped from
# the sed, the opening quote binds further along and swallows this merge.
check BLOCKED "merge past a \\\\ desync"      api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"a\\"}) { thread { id } } mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "merge past 2nd field, plain" api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "graphql aliased merge"       api graphql -f 'query=mutation { m: mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "graphql merge, no whitespace" api graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"x"}){clientMutationId}}'
# Newline between a field name and its `(`. grep matches per line, so
# `[[:space:]]` cannot span one: the name line has no `(` and the `(` line has
# no name, so extraction dropped the field SILENTLY. Needs an allow-listed
# neighbour - alone it fails closed on the die-on-empty, which is exactly what
# made this hide. Confirmed at the server before the fix (GitHub dispatched
# mergePullRequest and returned NOT_FOUND on the bogus node id).
check BLOCKED "merge, newline before its (" api graphql -f 'query=mutation {
  addPullRequestReviewThread(input:{body:"hi"}) { thread { id } }
  mergePullRequest
  (input:{pullRequestId:"x"}) { clientMutationId }
}'
check BLOCKED "merge alone, newline before (" api graphql -f 'query=mutation {
  mergePullRequest
  (input:{pullRequestId:"x"}) { clientMutationId }
}'
check BLOCKED "createCommitOnBranch, newline" api graphql -f 'query=mutation {
  resolveReviewThread(input:{threadId:"x"}) { thread { isResolved } }
  createCommitOnBranch
  (input:{}) { commit { oid } }
}'
check BLOCKED "deleteRef, newline before ("  api graphql -f 'query=mutation {
  resolveReviewThread(input:{threadId:"x"}) { thread { isResolved } }
  deleteRef
  (input:{refId:"x"}) { clientMutationId }
}'
# The other Ignored tokens. GraphQL treats Comma and Comment as separators
# exactly like whitespace, so each splits `name` from `(` the same way the
# newline did. Every row below was confirmed DISPATCHED before the fix.
check BLOCKED "merge, comma before its ("   api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } mergePullRequest,(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "merge, spaced comma"         api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } mergePullRequest , (input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "merge, doubled comma"        api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } mergePullRequest,,(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "merge, aliased + comma"      api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } m: mergePullRequest,(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "deleteRef, comma before ("   api graphql -f 'query=mutation { resolveReviewThread(input:{threadId:"x"}) { thread { isResolved } } deleteRef,(input:{refId:"x"}) { clientMutationId } }'
# Comment cases. A bare `#` or one ending in punctuation leaves nothing for
# the extractor to mis-read, which is precisely why it sailed through.
check BLOCKED "merge, bare # comment"       api graphql -f 'query=mutation {
  addPullRequestReviewThread(input:{body:"hi"}) { thread { id } }
  mergePullRequest #
  (input:{pullRequestId:"x"}) { clientMutationId }
}'
check BLOCKED "merge, # comment w/ punct"   api graphql -f 'query=mutation {
  addPullRequestReviewThread(input:{body:"hi"}) { thread { id } }
  mergePullRequest # see [1]
  (input:{pullRequestId:"x"}) { clientMutationId }
}'
# The name-alone backstop: even with NO `(` anywhere near it, a denied name
# sitting in executable text is refused. This is the net under the extractor
# - if a future Ignored-token trick defeats parsing again, it fails closed.
check BLOCKED "denied name, no call syntax" api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } mergePullRequest }'
# These two pin the NORMALIZATION on its own. The rows above are caught by
# either layer, so they pass even with the separator handling reverted (the
# name backstop picks them up) - they pin the guard as a whole, not this
# step. An unknown mutation is on neither the allow list nor the deny list,
# so ONLY correct separator handling can surface it: revert the comma fold
# or the comment strip and these two flip to allowed.
check BLOCKED "unknown mutation, comma sep" api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"hi"}) { thread { id } } someMutationNobodyAllowListed,(input:{}) { id } }'
check BLOCKED "unknown mutation, # comment" api graphql -f 'query=mutation {
  addPullRequestReviewThread(input:{body:"hi"}) { thread { id } }
  someMutationNobodyAllowListed #
  (input:{}) { id }
}'

echo "MUST ALLOW:"
check allowed "GET user"                    api user
check allowed "GET git/commits (tree sha)"  api "repos/$R/git/commits/f43b11b"
check allowed "GET git/refs"                api "repos/$R/git/refs/heads/main"
check allowed "GET actions runs"            api "repos/$R/actions/runs?per_page=1"
check allowed "GET contents"                api "repos/$R/contents/README.md"
check allowed "GET pr diff"                 pr diff 5 --repo "$R"
check allowed "run list (read verb)"        run list --repo "$R" --limit 1
check allowed "graphql read query"          api graphql -f 'query={viewer{login}}'
check allowed "graphql resolveReviewThread" api graphql -f 'query=mutation { resolveReviewThread(input:{threadId:"PRRT_bogus"}) { thread { isResolved } } }'
check allowed "graphql addReviewThread"     api graphql -f 'query=mutation { addPullRequestReviewThread(input:{}) { thread { id } } }'
# The mutation carries the comment body inside it, and a review comment
# nearly always names a function. `input:{}` above is the one shape of this
# mutation that cannot trip the field extractor, so it proves nothing on its
# own - these two pin it. The second also names a *denied* mutation inside
# the body, which is data and must not be read as a call.
check allowed "review body with parens"     api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"check() reads the wrong exit code"}) { thread { id } } }'
check allowed "review body naming a merge"  api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"call mergePullRequest(input:{}) here"}) { thread { id } } }'
# The desync fix must not over-block: a body legitimately ending in an
# escaped backslash, and one containing an escaped quote, both still post.
check allowed "body ending in \\\\"          api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"the path is C:\\"}) { thread { id } } }'
check allowed "body with escaped quote"     api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"he said \"check() is wrong\" here"}) { thread { id } } }'
check allowed "graphql named op + variable" api graphql -F threadId=x -f 'query=mutation Resolve($threadId: ID!) { resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } } }'
# The newline fold must not over-block. This is the shape a real reviewer
# actually emits: a pretty-printed multi-line mutation whose comment body is
# prose ABOUT merging and contains parens. Only the two review mutations may
# be extracted from it.
check allowed "multi-line review, merge in body" api graphql -f 'query=mutation {
  addPullRequestReviewThread(input:{
    body:"check() drops the code here, and mergePullRequest(input:{}) would be wrong"
  }) { thread { id } }
  resolveReviewThread(input:{threadId:"x"}) { thread { isResolved } }
}'
# The comment strip and comma fold must not over-block the reviewer's own
# output. A review body routinely contains `#` (issue refs) and commas, and
# the argument list itself is comma-separated - none of that may be read as
# a separator hiding a call, because literals are stripped first.
check allowed "body with # issue refs"      api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"see PR #6 and issue #12, check() is wrong"}) { thread { id } } }'
check allowed "body with a bare # at end"   api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"the marker is #"}) { thread { id } } }'
check allowed "comma-separated arguments"   api graphql -f 'query=mutation { addPullRequestReviewThread(input:{pullRequestId:"a", body:"b", path:"c", line:1}) { thread { id } } }'
# The backstop keys on the NAME, so a name that merely CONTAINS a denied one
# must not trip it - this is the false-positive that a substring match would
# cause and a word match must not.
check allowed "allow-listed name, merge-ish substring" api graphql -f 'query=mutation { addPullRequestReviewThread(input:{body:"mergePullRequestId is the arg"}) { thread { id } } }'
check allowed "POST a review (approve)"     api -X POST "repos/$R/pulls/999999/reviews" -f event=APPROVE -f body=x
check allowed "POST a review comment"       api -X POST "repos/$R/pulls/999999/comments" -f body=x
check allowed "PATCH own review comment"    api -X PATCH "repos/$R/pulls/comments/1" -f body=x
check allowed "POST an issue comment"       api -X POST "repos/$R/issues/999999/comments" -f body=x
# A REST body is not a graphql query. review.json mentions a mutation and
# contains `name(`; if the graphql scanner ever sees a REST body again,
# these two fail. This is how review payloads are actually posted.
check allowed "REST POST --input <file>"    api "repos/$R/pulls/999999/reviews" --method POST --input "$TMP/review.json"
check allowed "REST POST --input - (stdin)" api "repos/$R/pulls/999999/reviews" --method POST --input -
check allowed "pr comment w/ merge in body" pr comment 999999 --repo "$R" --body 'we should call mergePullRequest here'
check allowed "pr review --approve"         pr review 999999 --repo "$R" --approve --body 'LGTM'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
