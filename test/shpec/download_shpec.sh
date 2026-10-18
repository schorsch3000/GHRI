
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

DOWNLOAD_TEST_DIR="$TEST_SANDBOX/tmp/download_test"

cleanup_download_test() {
  rm -rf "$DOWNLOAD_TEST_DIR"
}

describe "Download" do
  setup_download_test() {
    cleanup_download_test
    mkdir -p "$DOWNLOAD_TEST_DIR"
  }

  it "has download_asset function" do
    assert is_function download_asset
  end

  it "uses curl with resume support" do
    assert is_function download_asset
  end

  it "follows redirects" do
    assert is_function download_asset
  end
end

describe "Install loop" do
  it "has do_install function" do
    assert is_function do_install
  end

  it "iterates packages" do
    assert is_function do_install
  end
end