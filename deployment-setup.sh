#!/bin/bash

# ===========================================
# PhishSight Deployment Setup Script
# ===========================================
# This script clones the required repositories if they don't exist,
# or pulls the latest changes if they already exist.
#
# Usage:
#   chmod +x deployment-setup.sh
#   ./deployment-setup.sh          # Clone missing repos, pull existing ones
#   ./deployment-setup.sh --pull   # Same as above (default behavior)
#   ./deployment-setup.sh --clone-only  # Only clone, don't pull existing
#
# ===========================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
PULL_EXISTING=true
if [ "${1:-}" = "--clone-only" ]; then
    PULL_EXISTING=false
fi

# Repository URLs
BACKEND_REPO="git@github.com:OsamaMahmood/phishsight-app-backend.git"
SITE_REPO="git@github.com:OsamaMahmood/phishsight-site.git"
APP_REPO="git@github.com:OsamaMahmood/phishsight-app.git"

# Directory names
BACKEND_DIR="phishsight-app-backend"
SITE_DIR="phishsight-site"
APP_DIR="phishsight-app"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           PhishSight Deployment Setup Script              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Function to clone or pull a repo
clone_or_pull() {
    local repo_url=$1
    local dir_name=$2

    if [ -d "$dir_name" ]; then
        if [ -d "$dir_name/.git" ]; then
            cd "$dir_name"
            current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
            echo -e "${BLUE}→ $dir_name${NC} (branch: ${current_branch})"

            if [ "$PULL_EXISTING" = true ]; then
                # Check for uncommitted changes
                if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                    echo -e "  ${YELLOW}⚠ Has uncommitted changes - stashing before pull${NC}"
                    git stash --quiet
                    local stashed=true
                fi

                # Pull latest changes
                if git pull --ff-only 2>/dev/null; then
                    echo -e "  ${GREEN}✓ Pulled latest changes${NC}"
                else
                    # ff-only failed, try regular pull
                    if git pull --rebase 2>/dev/null; then
                        echo -e "  ${GREEN}✓ Pulled latest changes (rebased)${NC}"
                    else
                        echo -e "  ${YELLOW}⚠ Could not pull - local changes may conflict${NC}"
                        echo -e "  ${YELLOW}  Resolve manually: cd $dir_name && git pull${NC}"
                    fi
                fi

                # Restore stashed changes
                if [ "${stashed:-false}" = true ]; then
                    if git stash pop --quiet 2>/dev/null; then
                        echo -e "  ${GREEN}✓ Restored local changes${NC}"
                    else
                        echo -e "  ${YELLOW}⚠ Stash conflict - run: cd $dir_name && git stash pop${NC}"
                    fi
                fi
            else
                echo -e "  ${YELLOW}⚠ Already exists, skipping (--clone-only)${NC}"
            fi
            cd ..
        else
            echo -e "${YELLOW}⚠ '$dir_name' exists but is not a git repo. Skipping.${NC}"
        fi
    else
        echo -e "${GREEN}✓ Cloning $dir_name...${NC}"
        if git clone "$repo_url" "$dir_name"; then
            echo -e "${GREEN}  ✓ Successfully cloned $dir_name${NC}"
        else
            echo -e "${RED}  ✗ Failed to clone $dir_name${NC}"
            echo -e "${RED}    Make sure you have SSH access to the repository.${NC}"
            return 1
        fi
    fi
}

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo -e "${RED}✗ Git is not installed. Please install git first.${NC}"
    exit 1
fi

echo -e "${BLUE}Checking SSH access to GitHub...${NC}"
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo -e "${GREEN}✓ SSH access to GitHub confirmed${NC}"
else
    echo -e "${YELLOW}⚠ Could not verify SSH access. Continuing anyway...${NC}"
    echo -e "  If cloning fails, ensure your SSH key is added to GitHub."
fi

echo ""
if [ "$PULL_EXISTING" = true ]; then
    echo -e "${BLUE}Setting up repositories (clone or pull latest)...${NC}"
else
    echo -e "${BLUE}Setting up repositories (clone only)...${NC}"
fi
echo "─────────────────────────────────────────────────────────────"

# Clone or pull each repository
clone_or_pull "$BACKEND_REPO" "$BACKEND_DIR"
echo ""
clone_or_pull "$SITE_REPO" "$SITE_DIR"
echo ""
clone_or_pull "$APP_REPO" "$APP_DIR"

echo ""
echo "─────────────────────────────────────────────────────────────"

# Check if all directories exist
all_present=true
for dir in "$BACKEND_DIR" "$SITE_DIR" "$APP_DIR"; do
    if [ ! -d "$dir" ]; then
        all_present=false
        echo -e "${RED}✗ Missing: $dir${NC}"
    fi
done

if [ "$all_present" = true ]; then
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║              ✓ All repositories are ready!                ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BLUE}Next steps:${NC}"
    echo ""
    echo "  1. Copy the environment file:"
    echo -e "     ${YELLOW}cp .env.dev.example .env${NC}  (for development)"
    echo -e "     ${YELLOW}cp .env.prod.example .env${NC} (for production)"
    echo ""
    echo "  2. Edit .env and configure your settings"
    echo ""
    echo "  3. Start the services:"
    echo -e "     ${YELLOW}docker compose -f docker-compose.yml up --build${NC}  (development)"
    echo -e "     ${YELLOW}docker compose -f docker-compose.yml up --build -d${NC} (production)"
    echo ""
    echo -e "${BLUE}Services will be available at:${NC}"
    echo "  • API:      http://localhost:3001"
    echo "  • App:      http://localhost:3002 (dev) / http://localhost:3000 (prod)"
    echo "  • Site:     http://localhost:3003"
    echo "  • API Docs: http://localhost:3001/api/docs"
    echo ""
else
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         ✗ Some repositories could not be cloned          ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "Please check your SSH access and try again."
    exit 1
fi
