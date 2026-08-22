#!/usr/bin/env bash
# Rewrite the Homebrew tap for a release: the app cask (per-architecture DMGs,
# issue #774) and the standalone speak CLI formula (issue #775).
#
# Usage: ./scripts/update-homebrew-tap.sh <version> <arm64-dmg-sha256> <universal-dmg-sha256> \
#            [<cli-arm64-zip-sha256> <cli-x86_64-zip-sha256>]
#
# Environment:
#   GH_TOKEN   token with push access to the tap (required unless TAP_DIR is a
#              clone the caller will push, or DRY_RUN is set)
#   TAP_DIR    existing clone of the tap to update in place (default: a fresh
#              clone under a temporary directory)
#   TAP_REPO   GitHub repository of the tap (default crmitchelmore/homebrew-justspeaktoit)
#   DRY_RUN    when set, writes and syntax-checks the files but neither commits nor pushes
#
# The CLI shas are optional so that a failed CLI publication never blocks the
# app release: without them the formula is left as it is and the cask only
# depends on it when a formula already exists in the tap.

set -euo pipefail

VERSION="${1:-}"
ARM64_SHA256="${2:-}"
UNIVERSAL_SHA256="${3:-}"
CLI_ARM64_SHA256="${4:-}"
CLI_X86_64_SHA256="${5:-}"
TAP_REPO="${TAP_REPO:-crmitchelmore/homebrew-justspeaktoit}"

if [[ -z "$VERSION" || -z "$ARM64_SHA256" || -z "$UNIVERSAL_SHA256" ]]; then
    echo "Usage: $0 <version> <arm64-dmg-sha256> <universal-dmg-sha256> [<cli-arm64-sha256> <cli-x86_64-sha256>]" >&2
    exit 1
fi
if [[ -n "$CLI_ARM64_SHA256" && -z "$CLI_X86_64_SHA256" ]] || [[ -z "$CLI_ARM64_SHA256" && -n "$CLI_X86_64_SHA256" ]]; then
    echo "error: supply both CLI shas or neither" >&2
    exit 1
fi
for sha in "$ARM64_SHA256" "$UNIVERSAL_SHA256" $CLI_ARM64_SHA256 $CLI_X86_64_SHA256; do
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "error: '$sha' is not a lowercase hex SHA-256" >&2
        exit 1
    fi
done

if [[ -z "${TAP_DIR:-}" ]]; then
    if [[ -z "${GH_TOKEN:-}" && -z "${DRY_RUN:-}" ]]; then
        echo "error: GH_TOKEN is required to clone and push the tap" >&2
        exit 1
    fi
    TAP_DIR="$(mktemp -d)/homebrew-tap"
    if [[ -n "${GH_TOKEN:-}" ]]; then
        git clone --quiet "https://x-access-token:${GH_TOKEN}@github.com/${TAP_REPO}.git" "$TAP_DIR"
    else
        git clone --quiet "https://github.com/${TAP_REPO}.git" "$TAP_DIR"
    fi
fi
cd "$TAP_DIR"
mkdir -p Casks Formula

PUBLISH_CLI=false
if [[ -n "$CLI_ARM64_SHA256" ]]; then
    PUBLISH_CLI=true
fi

RELEASE_URL="https://github.com/crmitchelmore/justspeaktoit/releases/download/mac-v#{version}"

if [[ "$PUBLISH_CLI" == true ]]; then
    echo "==> Writing Formula/speak.rb for $VERSION"
    cat > Formula/speak.rb << EOF
class Speak < Formula
  desc "Terminal and agent automation client for Just Speak to It"
  homepage "https://justspeaktoit.com"
  version "$VERSION"
  license "MIT"

  livecheck do
    url :stable
    regex(/^mac-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_latest
  end

  depends_on macos: :sonoma

  on_macos do
    on_arm do
      url "${RELEASE_URL}/speak-#{version}-arm64.zip"
      sha256 "$CLI_ARM64_SHA256"
    end

    on_intel do
      url "${RELEASE_URL}/speak-#{version}-x86_64.zip"
      sha256 "$CLI_X86_64_SHA256"
    end
  end

  def install
    bin.install "speak"
  end

  def caveats
    <<~EOS
      speak talks to the Just Speak to It app over its local automation socket;
      install the app (brew install --cask justspeaktoit) and enable Automation
      in its Settings.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/speak --version")
  end
end
EOF
fi

# The cask depends on the formula once the tap carries one, so every Homebrew
# install gets the standalone CLI rather than a link into the app bundle.
CASK_CLI_DEPENDENCY=""
if [[ -f Formula/speak.rb ]]; then
    CASK_CLI_DEPENDENCY=$'\n  depends_on formula: "crmitchelmore/justspeaktoit/speak"'
fi

echo "==> Writing Casks/justspeaktoit.rb for $VERSION"
cat > Casks/justspeaktoit.rb << EOF
cask "justspeaktoit" do
  arch arm: "arm64", intel: "universal"

  version "$VERSION"
  sha256 arm:   "$ARM64_SHA256",
         intel: "$UNIVERSAL_SHA256"

  url "${RELEASE_URL}/JustSpeakToIt-#{arch}.dmg"
  name "Just Speak to It"
  desc "Voice transcription with on-device or cloud processing"
  homepage "https://justspeaktoit.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma${CASK_CLI_DEPENDENCY}

  app "JustSpeakToIt.app"

  zap trash: [
    "~/Library/Application Support/SpeakApp",
    "~/Library/Caches/com.justspeaktoit.mac",
    "~/Library/Preferences/com.justspeaktoit.mac.plist",
  ]
end
EOF

for file in Casks/justspeaktoit.rb Formula/speak.rb; do
    [[ -f "$file" ]] || continue
    chmod 644 "$file"
    ruby -c "$file" > /dev/null
    echo "==> $file:"
    cat "$file"
done

if [[ -n "${DRY_RUN:-}" ]]; then
    echo "==> DRY_RUN set; not committing"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add Casks/justspeaktoit.rb
if [[ "$PUBLISH_CLI" == true ]]; then
    git add Formula/speak.rb
fi
if git diff --cached --quiet; then
    echo "==> Tap already up to date for $VERSION"
    exit 0
fi
git commit --quiet -m "Update Just Speak to It to v$VERSION"
git push --quiet
echo "==> Homebrew tap updated for $VERSION"
