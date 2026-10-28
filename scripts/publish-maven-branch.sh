#!/usr/bin/env bash
# Builds the JAR in Docker and publishes it into a static Maven folder that lives on the `maven` branch.
# GitHub then serves it at
#   https://raw.githubusercontent.com/Privatus-Analytics/enonic-privatus-analytics/maven/
#
#   ./scripts/publish-maven-branch.sh          # build, publish and commit on the maven branch (no push)
#   PUSH=1 ./scripts/publish-maven-branch.sh   # same, then push the maven branch
#
# The script starts from the existing maven branch, so maven-metadata.xml keeps every earlier version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$ROOT/build/maven-repo"
REMOTE="${REMOTE:-origin}"
JDK_IMAGE="${JDK_IMAGE:-eclipse-temurin:25-jdk}"
VERSION="$(sed -n 's/^version *= *//p' "$ROOT/gradle.properties")"

cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first, so the JAR matches a commit." >&2
  exit 1
fi
SOURCE_COMMIT="$(git rev-parse --short HEAD)"

echo "==> Checking out the maven branch into build/maven-repo"
rm -rf "$REPO_DIR"
if git ls-remote --exit-code --heads "$REMOTE" maven >/dev/null 2>&1; then
  git fetch "$REMOTE" maven
  git worktree prune
  git worktree add -f "$REPO_DIR" "$REMOTE/maven" --detach
  (cd "$REPO_DIR" && git checkout -B maven)
else
  git worktree prune
  git worktree add -f --detach "$REPO_DIR"
  (cd "$REPO_DIR" && git checkout --orphan maven && git rm -rfq . && git clean -fdxq)
  printf '# Maven repository\n\nStatic Maven repository for the Privatus Analytics app for Enonic XP.\nURL: https://raw.githubusercontent.com/Privatus-Analytics/enonic-privatus-analytics/maven/\n' >"$REPO_DIR/README.md"
fi

if [[ -d "$REPO_DIR/com/privatusanalytics/privatus-analytics/$VERSION" ]]; then
  echo "Version $VERSION is already on the maven branch. Bump version in gradle.properties first." >&2
  exit 1
fi

echo "==> Building and publishing $VERSION in Docker"
docker volume create privatus-analytics-gradle >/dev/null
# No `clean` here: it would delete the worktree in build/maven-repo.
docker run --rm -v "$ROOT":/app -v privatus-analytics-gradle:/root/.gradle -w /app "$JDK_IMAGE" \
  ./gradlew --no-daemon -q build publish

echo "==> Committing on the maven branch"
cd "$REPO_DIR"
git add -A
git commit -q -m "Publish privatus-analytics $VERSION (from $SOURCE_COMMIT)"
git log --oneline -1

JAR_URL="https://raw.githubusercontent.com/Privatus-Analytics/enonic-privatus-analytics/maven/com/privatusanalytics/privatus-analytics/$VERSION/privatus-analytics-$VERSION.jar"
if [[ "${PUSH:-0}" == "1" ]]; then
  git push "$REMOTE" maven
  echo "Published: $JAR_URL"
else
  echo "Not pushed. To push: (cd build/maven-repo && git push $REMOTE maven)"
  echo "The JAR will then be at: $JAR_URL"
fi
