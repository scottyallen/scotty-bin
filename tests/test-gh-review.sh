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

check() {
  local want="$1" desc="$2"; shift 2
  "$GH_REVIEW" "$@" >/dev/null 2>&1
  local rc=$?
  local got
  case $rc in
    3)   got="BLOCKED" ;;
    2|4) got="WRAPPER-ERROR" ;;   # usage / missing token - never a pass
    *)   got="allowed" ;;
  esac
  if [ "$got" = "$want" ]; then
    printf '  ok    %-9s %s\n' "$got" "$desc"; pass=$((pass+1))
  else
    printf '  FAIL  got=%-13s want=%-9s %s\n' "$got" "$want" "$desc"; fail=$((fail+1))
  fi
}

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
check allowed "graphql named op + variable" api graphql -F threadId=x -f 'query=mutation Resolve($threadId: ID!) { resolveReviewThread(input:{threadId:$threadId}) { thread { isResolved } } }'
check allowed "POST a review (approve)"     api -X POST "repos/$R/pulls/999999/reviews" -f event=APPROVE -f body=x
check allowed "POST a review comment"       api -X POST "repos/$R/pulls/999999/comments" -f body=x
check allowed "PATCH own review comment"    api -X PATCH "repos/$R/pulls/comments/1" -f body=x
check allowed "POST an issue comment"       api -X POST "repos/$R/issues/999999/comments" -f body=x
check allowed "pr comment w/ merge in body" pr comment 999999 --repo "$R" --body 'we should call mergePullRequest here'
check allowed "pr review --approve"         pr review 999999 --repo "$R" --approve --body 'LGTM'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
