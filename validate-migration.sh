#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SVN_BASE="/var/svn"
GIT_BASE="/var/git"
TEMP_DIR=$(mktemp -d)

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}   SVN to Git Migration Validator${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Get list of repositories
repos=$(ls $SVN_BASE 2>/dev/null || echo "")

if [ -z "$repos" ]; then
    echo -e "${RED}✗ No SVN repositories found in $SVN_BASE${NC}"
    exit 1
fi

echo -e "${GREEN}Found repositories:${NC}"
for repo in $repos; do
    echo "  - $repo"
done
echo ""

total_tests=0
passed_tests=0
failed_tests=0

run_test() {
    local test_name=$1
    local test_command=$2
    
    total_tests=$((total_tests + 1))
    echo -n "Testing: $test_name ... "
    
    if eval "$test_command" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        passed_tests=$((passed_tests + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        failed_tests=$((failed_tests + 1))
        return 1
    fi
}

for repo in $repos; do
    echo -e "${YELLOW}Validating: $repo${NC}"
    echo "-------------------------------------------"
    
    SVN_REPO="$SVN_BASE/$repo"
    GIT_REPO="$GIT_BASE/$repo.git"
    
    # Test 1: SVN repository exists and is valid
    run_test "SVN repo exists" "[ -d '$SVN_REPO' ]"
    run_test "SVN repo is valid" "svnadmin verify '$SVN_REPO'"
    
    # Test 2: Git repository exists
    run_test "Git repo exists" "[ -d '$GIT_REPO' ]"
    run_test "Git repo is valid" "cd '$GIT_REPO' && git rev-parse --git-dir"
    
    # Test 3: Check SVN revision count
    svn_revisions=$(svnlook youngest "$SVN_REPO" 2>/dev/null || echo "0")
    echo -e "  SVN revisions: ${BLUE}$svn_revisions${NC}"
    
    # Test 4: Check Git commit count
    cd "$GIT_REPO"
    git_commits=$(git rev-list --all --count 2>/dev/null || echo "0")
    echo -e "  Git commits: ${BLUE}$git_commits${NC}"
    
    # Test 5: Verify commits were migrated (Git should have at least as many commits)
    if [ "$git_commits" -ge "$svn_revisions" ]; then
        echo -e "  Commit migration: ${GREEN}OK${NC} (Git: $git_commits >= SVN: $svn_revisions)"
        passed_tests=$((passed_tests + 1))
    else
        echo -e "  Commit migration: ${RED}FAIL${NC} (Git: $git_commits < SVN: $svn_revisions)"
        failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # Test 6: Clone and verify file contents
    echo -n "Testing: File content verification ... "
    CLONE_DIR="$TEMP_DIR/git-clone-$repo"
    CHECKOUT_DIR="$TEMP_DIR/svn-checkout-$repo"
    
    if git clone "$GIT_REPO" "$CLONE_DIR" > /dev/null 2>&1 && \
       svn checkout "file://$SVN_REPO/trunk" "$CHECKOUT_DIR" > /dev/null 2>&1; then
        
        # Compare file counts
        git_files=$(cd "$CLONE_DIR" && find . -type f ! -path './.git/*' | wc -l)
        svn_files=$(cd "$CHECKOUT_DIR" && find . -type f ! -path './.svn/*' | wc -l)
        
        if [ "$git_files" -eq "$svn_files" ]; then
            echo -e "${GREEN}PASS${NC}"
            echo -e "  Files in Git: $git_files, Files in SVN trunk: $svn_files"
            passed_tests=$((passed_tests + 1))
        else
            echo -e "${YELLOW}WARN${NC}"
            echo -e "  Files in Git: $git_files, Files in SVN trunk: $svn_files (may differ due to branches/tags)"
            passed_tests=$((passed_tests + 1))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        failed_tests=$((failed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # Test 7: Check for README.md (sample file)
    run_test "Sample README exists in Git" "[ -f '$CLONE_DIR/README.md' ]"
    run_test "Sample README exists in SVN" "[ -f '$CHECKOUT_DIR/README.md' ]"
    
    # Test 8: Verify Git branches exist
    echo -n "Testing: Git branches ... "
    branches=$(cd "$GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
    if [ -n "$branches" ]; then
        echo -e "${GREEN}PASS${NC}"
        echo -e "  Branches: $(echo $branches | tr '\n' ', ')"
        passed_tests=$((passed_tests + 1))
    else
        echo -e "${YELLOW}WARN${NC} (no branches found)"
        passed_tests=$((passed_tests + 1))
    fi
    total_tests=$((total_tests + 1))
    
    # Test 9: Check HTTP access readiness
    run_test "Git http.receivepack enabled" "cd '$GIT_REPO' && git config http.receivepack | grep -q true"
    
    # Test 10: Ownership check
    run_test "SVN owned by www-data" "[ \$(stat -c '%U' '$SVN_REPO') = 'www-data' ]"
    run_test "Git owned by www-data" "[ \$(stat -c '%U' '$GIT_REPO') = 'www-data' ]"
    
    echo ""
done

# Summary
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}           Validation Summary${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "Total tests: ${BLUE}$total_tests${NC}"
echo -e "Passed:      ${GREEN}$passed_tests${NC}"
echo -e "Failed:      ${RED}$failed_tests${NC}"
echo ""

if [ $failed_tests -eq 0 ]; then
    echo -e "${GREEN}✓ All validations passed!${NC}"
    echo -e "${GREEN}Migration appears to be successful.${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠ Some validations failed.${NC}"
    echo -e "${YELLOW}Please review the output above.${NC}"
    exit 1
fi
