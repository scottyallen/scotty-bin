#!/usr/bin/env bash
# Guard tests for ~/bin/gh-review. Exit 3 == blocked by the wrapper's deny
# lists; any other exit == the guard let it through to gh (which may then
# 404, that's fine - we are testing the guard, not the API).
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

check() {
  local want="$1" desc="$2"; shift 2
  "$GH_REVIEW" "$@" >/dev/null 2>&1
  local rc=$?
  local got="allowed"; [ "$rc" -eq 3 ] && got="BLOCKED"
  if [ "$got" = "$want" ]; then
    printf '  ok    %-9s %s\n' "$got" "$desc"; pass=$((pass+1))
  else
    printf '  FAIL  got=%-9s want=%-9s %s\n' "$got" "$want" "$desc"; fail=$((fail+1))
  fi
}

echo "MUST BLOCK:"
check BLOCKED "pr merge"                    pr merge 5 --repo "$R"
check BLOCKED "pr close"                    pr close 5 --repo "$R"
check BLOCKED "pr create"                   pr create --repo "$R" --title x --body y
check BLOCKED "repo delete"                 repo delete "$R"
check BLOCKED "workflow run"                workflow run deploy.yml --repo "$R"
check BLOCKED "REST merge endpoint"         api -X PUT "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, lowercase -X"    api -X put "repos/$R/pulls/5/merge"
check BLOCKED "REST merge, glued -XPUT"     api -XPUT "repos/$R/pulls/5/merge"
check BLOCKED "POST git/refs (push)"        api -X POST "repos/$R/git/refs" -f ref=refs/heads/x
check BLOCKED "POST git/commits"            api -X POST "repos/$R/git/commits" -f message=x
check BLOCKED "PUT contents (edit file)"    api -X PUT "repos/$R/contents/README.md" -f message=x
check BLOCKED "DELETE branch protection"    api -X DELETE "repos/$R/branches/main/protection"
check BLOCKED "PUT collaborators"           api -X PUT "repos/$R/collaborators/someone"
check BLOCKED "graphql mergePullRequest"    api graphql -f 'query=mutation { mergePullRequest(input:{pullRequestId:"x"}) { clientMutationId } }'
check BLOCKED "graphql createCommitOnBranch" api graphql -f 'query=mutation { createCommitOnBranch(input:{}) { commit { oid } } }'
check BLOCKED "graphql deleteRef"           api graphql -f 'query=mutation { deleteRef(input:{refId:"x"}) { clientMutationId } }'

echo "MUST ALLOW:"
check allowed "GET user"                    api user
check allowed "GET git/commits (tree sha)"  api "repos/$R/git/commits/f43b11b"
check allowed "GET git/refs"                api "repos/$R/git/refs/heads/main"
check allowed "GET actions runs"            api "repos/$R/actions/runs?per_page=1"
check allowed "GET contents"                api "repos/$R/contents/README.md"
check allowed "GET pr diff"                 pr diff 5 --repo "$R"
check allowed "graphql resolveReviewThread" api graphql -f 'query=mutation { resolveReviewThread(input:{threadId:"PRRT_bogus"}) { thread { isResolved } } }'
check allowed "graphql addReviewThread"     api graphql -f 'query=mutation { addPullRequestReviewThread(input:{}) { thread { id } } }'
check allowed "POST a review (approve)"     api -X POST "repos/$R/pulls/999999/reviews" -f event=APPROVE -f body=x
check allowed "pr comment w/ merge in body" pr comment 999999 --repo "$R" --body 'we should call mergePullRequest here'
check allowed "pr review --approve"         pr review 999999 --repo "$R" --approve --body 'LGTM'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
