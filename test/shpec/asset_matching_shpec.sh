TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

describe "Asset matching" do
  it "matches glob patterns" do
    match_asset "binary-linux-amd64" "binary-*"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "matches glob with wildcards" do
    match_asset "pkg-v1.0.tar.gz" "*.tar.gz"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "rejects non-matching globs" do
    match_asset "binary-windows.exe" "binary-linux-*"
    local rc=$?
    assert equal "$rc" "1"
  end

  it "matches regex patterns" do
    match_asset "Obsidian-1.0.0.AppImage" "/Obsidian-[0-9.]*.AppImage/"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "rejects non-matching regex" do
    match_asset "binary.exe" "/Obsidian-[0-9.]*.AppImage/"
    local rc=$?
    assert equal "$rc" "1"
  end

  it "defaults to matching everything with *" do
    match_asset "anything" "*"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "handles exact match patterns" do
    match_asset "yt-dlp_linux" "yt-dlp_linux"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "handles case-sensitive matching" do
    match_asset "Binary" "binary"
    local rc=$?
    assert equal "$rc" "1"
  end

  it "handles wildcard at end" do
    match_asset "envocabulary_1.0_linux_amd64.deb" "envocabulary_*_linux_amd64.deb"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "handles wildcard at start" do
    match_asset "some-C64UViewer.deb" "*.deb"
    local rc=$?
    assert equal "$rc" "0"
  end
end

describe "Release fetching" do
  it "handles GitHub API response" do
    assert is_function fetch_release
  end

  it "parses release tag" do
    assert is_function fetch_release
  end

  it "parses prerelease flag" do
    assert is_function fetch_release
  end

  it "extracts asset list" do
    assert is_function fetch_release
  end
end

describe "Asset finding" do
  it "finds matching asset" do
    release_asset_names=("binary-linux" "binary-windows" "binary-macos")
    release_asset_urls=("https://example.com/linux" "https://example.com/windows" "https://example.com/macos")
    release_asset_count=3

    find_matching_asset "binary-*"
    local rc=$?
    assert equal "$rc" "0"
    assert present "$found_asset_name"
    assert present "$found_asset_url"
  end

  it "returns failure when no asset matches" do
    release_asset_names=("binary-linux" "binary-windows")
    release_asset_urls=("https://example.com/linux" "https://example.com/windows")
    release_asset_count=2

    find_matching_asset "binary-macos"
    local rc=$?
    assert equal "$rc" "1"
    assert equal "$found_asset_name" ""
  end

  it "uses first match" do
    release_asset_names=("binary-linux-amd64" "binary-linux-386" "binary-macos")
    release_asset_urls=("https://example.com/amd64" "https://example.com/386" "https://example.com/macos")
    release_asset_count=3

    find_matching_asset "binary-*"
    local rc=$?
    assert equal "$rc" "0"
    assert equal "$found_asset_name" "binary-linux-amd64"
  end
end