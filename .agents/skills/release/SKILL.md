---
name: release
description: Execute the rtp2httpd release workflow — tag, GitHub release, wait for CI, update stable branch.
---

# rtp2httpd Release Workflow

This skill orchestrates the entire release process for `rtp2httpd`.

## Workflow Steps

Follow these steps in order. Use `AskUserQuestion` for interactive choices. Use `Bash` for all shell commands.

---

### Step 0: Pre-flight Checks

- Ensure you are at the **rtp2httpd project root** (`cd` there first if needed).
- Check current branch with `git branch --show-current`.
- Check for uncommitted changes with `git status --porcelain`. If the workspace is not clean, abort with instructions.
- Determine the **latest release tag** using `gh release list --limit 1 --json tagName --jq '.[0].tagName'` (e.g., `v3.14.2`). Extract the version numbers.

---

### Step 1: Ask Release Type

Use `AskUserQuestion` with header "Release type":

> What type of release is this?

Options (single-select):
- **patch** — Bug fixes only (Z+1). Release notes are a simple bullet list.
- **minor** — New features + bug fixes (Y+1). Release notes split into "新功能 / 问题修复" (Chinese) and "New Features / Bug Fixes" (English), with donation QR code.
- **major** — Breaking changes (X+1). Same format as minor.

Based on the answer and latest version, compute the new tag (e.g., `v3.15.0`).

---

### Step 2: Draft Release Notes

Scrape recent git history since the last tag to inform the notes:

```bash
export LAST_TAG="v3.x.y"  # from step 0
git log "$LAST_TAG..HEAD" --oneline --no-merges --format="%s (%h)"
```

Categorize commits by type (`feat:`, `fix:`, `perf:`, `refactor:`, `chore:` etc.) to understand what went into this release.

Draft bilingual release notes **in a file** (e.g., `/tmp/release-notes-v3.x.y.md`) following these conventions:

**Patch release format:**
```markdown
- {Chinese description}
  - Detail if needed
- {Chinese description}

---

- {English description}
  - Detail if needed
- {English description}
```

**Minor/major release format:**
```markdown
## 新功能

- {feature description in Chinese}
  - Detail if needed
- ...

## 问题修复

- {fix description in Chinese}
  - Detail if needed
- ...

| 如果这个项目对你有帮助，不妨请作者喝一杯咖啡 ☕️ |
| --- |
| <img width="360" src="https://github.com/user-attachments/assets/fc5c3498-40e9-43b9-93a3-6a5a7917847b" /> |

---

## New Features

- {feature description in English}
  - Detail if needed
- ...

## Bug Fixes

- {fix description in English}
  - Detail if needed
- ...
```

**Release notes guidelines:**
- ✅ End-user focused — target audience is rtp2httpd users, not developers
- ✅ Avoid internal implementation details (e.g., "refactored X module", "upgraded Y dependency")
- ✅ Mention the web player / OpenWrt / Docker / specific feature areas where relevant
- ✅ Be concise; one short bullet per change with optional sub-bullet for context
- ✅ Bilingual: Chinese first, English second (separated by `---`)
- ❌ Do not include `Closes` / `Fixes #123` — those belong in git history only

Show the drafted notes to the user — output the **full release notes file content** (read it with `cat /tmp/release-notes-v3.x.y.md`) so the user can directly review the complete drafted notes.

### Step 3: Confirm with User

Use `AskUserQuestion` with header "Ready to release?":

> Ready to create release v3.x.y?

Show a summary: release notes file path, lint, tag creation, release creation, CI wait, stable branch update.

Options:
- **Yes, release it!** — proceed with the release
- **No, let me make changes first** — abort
- **No, let me edit release notes** — user edits the notes file, then mark task as complete

After user approval, continue.

---

### Step 4: Ensure on `main` with Clean Workspace

```bash
# Switch to main if not already there, only if workspace is clean
git checkout main
git pull origin main
```

If there are uncommitted changes preventing a branch switch, advise the user to stash or commit first and abort.

---

### Step 5: Build Web UI

First, install frontend dependencies to avoid stale local caches:

```bash
pnpm install
```

Then regenerate `src/embedded_web_data.h` so the released binary includes the latest frontend:

```bash
pnpm run web-ui:build
```

This updates `src/embedded_web_data.h`. Commit it if it changed:

```bash
git add src/embedded_web_data.h
git commit -m "chore: update embedded_web_data.h for v3.x.y"
```

If the file did not change (no diff), skip the commit.

---

### Step 6: Run Lint

```bash
pnpm run lint
```

If lint fails, show the output and ask the user whether to fix and retry or abort.

---

### Step 7: Create and Push Tag

```bash
git tag -a "v3.x.y" -m "v3.x.y"
git push origin "v3.x.y"
```

---

### Step 7: Create GitHub Release

```bash
gh release create "v3.x.y" \
  --title "v3.x.y" \
  --notes-file /tmp/release-notes-v3.x.y.md
```

After this, the CI release workflow is triggered automatically (it listens for `release.published` events).

---

### Step 8: Wait for CI `versioned` Job

The CI workflow has a `versioned` job that commits `Makefile.versioned` files back to the `main` branch. Wait for this commit to appear on `main`:

```bash
# Loop until the versioned makefiles commit appears on main
# The commit message pattern is "chore: update versioned Makefiles for v3.x.y"
while true; do
  git fetch origin main
  if git log origin/main --oneline --grep="versioned Makefiles for v3.x.y" | head -1 | grep -q "v3.x.y"; then
    echo "Versioned Makefiles commit found!"
    break
  fi
  echo "Waiting for versioned Makefiles commit... (retry in 30s)"
  sleep 30
done

# Update local main
git pull origin main
```

If the CI run fails or the commit doesn't appear within 10 minutes, alert the user and stop. Check CI status via:

```bash
# Get the latest workflow run ID for the release tag
gh run list --workflow=release.yaml --branch "v3.x.y" --limit 1 --json databaseId,status,conclusion --jq '.[0]'
```

---

### Step 9: Update `stable` Branch

```bash
git checkout stable
git pull origin stable
git merge --ff-only origin/main
git push origin stable
```

If `git merge --ff-only origin/main` fails (non-fast-forward), it means the `stable` branch has diverged — alert the user and abort. Do not force-push.

---

### Step 10: Return to `main`

```bash
git checkout main
```

---

### Step 11: Summary

Print a completion summary:

```
✅ Release v3.x.y complete!

- Tag: v3.x.y (pushed)
- GitHub Release: https://github.com/stackia/rtp2httpd/releases/tag/v3.x.y
- stable branch: updated (fast-forward merge)
- CI: running (Docker, OpenWRT, static binaries, macOS)
```

## Notes

- The CI release workflow (`release.yaml`) builds Docker images, OpenWRT IPK/APK packages, Linux/macOS/FreeBSD static binaries, and uploads them as release assets.
- The `versioned` job in the CI commits `openwrt-support/rtp2httpd/Makefile.versioned` and `openwrt-support/luci-app-rtp2httpd/Makefile.versioned` back to `main`.
- Never force-push to `main` or `stable`.
- Use `gh run list` and `gh run view` to monitor CI progress.
- If something goes wrong mid-release, communicate clearly what happened and what manual recovery steps are needed.
