TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

ARCHIVE_TEST_DIR="$TEST_SANDBOX/tmp/archive_test"

cleanup_archive_test() {
  rm -rf "$ARCHIVE_TEST_DIR"
}

describe "gunzip post-processor" do
  it "decompresses .gz files" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | gzip > "$ARCHIVE_TEST_DIR/test.gz"
    pp_gunzip "$ARCHIVE_TEST_DIR/test.gz"
    assert file_present "$ARCHIVE_TEST_DIR/test"
  end

  it "updates CURRENT_ASSET variable" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | gzip > "$ARCHIVE_TEST_DIR/test.gz"
    pp_gunzip "$ARCHIVE_TEST_DIR/test.gz"
    assert equal "$CURRENT_ASSET" "$ARCHIVE_TEST_DIR/test"
  end
end

describe "bz2 post-processor" do
  it "decompresses .bz2 files" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | bzip2 > "$ARCHIVE_TEST_DIR/test.bz2"
    pp_bz2 "$ARCHIVE_TEST_DIR/test.bz2"
    assert file_present "$ARCHIVE_TEST_DIR/test"
  end

  it "updates CURRENT_ASSET variable" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | bzip2 > "$ARCHIVE_TEST_DIR/test.bz2"
    pp_bz2 "$ARCHIVE_TEST_DIR/test.bz2"
    assert equal "$CURRENT_ASSET" "$ARCHIVE_TEST_DIR/test"
  end
end

describe "xz post-processor" do
  it "decompresses .xz files" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | xz > "$ARCHIVE_TEST_DIR/test.xz"
    pp_xz "$ARCHIVE_TEST_DIR/test.xz"
    assert file_present "$ARCHIVE_TEST_DIR/test"
  end

  it "updates CURRENT_ASSET variable" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "test content" | xz > "$ARCHIVE_TEST_DIR/test.xz"
    pp_xz "$ARCHIVE_TEST_DIR/test.xz"
    assert equal "$CURRENT_ASSET" "$ARCHIVE_TEST_DIR/test"
  end
end

describe "tar post-processor" do
  it "unarchives tar.gz file" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR/src/myapp"
    echo "content" > "$ARCHIVE_TEST_DIR/src/myapp/file.txt"
    tar -czf "$ARCHIVE_TEST_DIR/src/myapp.tar.gz" -C "$ARCHIVE_TEST_DIR/src" myapp
    cd "$ARCHIVE_TEST_DIR/src"
    pp_gunzip "myapp.tar.gz"
    pp_tar "myapp.tar"
    assert file_present "$ARCHIVE_TEST_DIR/src/myapp/file.txt"
    cd "$GHRI_DIR"
  end

  it "unarchives plain tar file" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR/src/myapp"
    echo "content" > "$ARCHIVE_TEST_DIR/src/myapp/file.txt"
    tar -cf "$ARCHIVE_TEST_DIR/src/myapp.tar" -C "$ARCHIVE_TEST_DIR/src" myapp
    cd "$ARCHIVE_TEST_DIR/src"
    pp_tar "myapp.tar"
    assert file_present "$ARCHIVE_TEST_DIR/src/myapp/file.txt"
    cd "$GHRI_DIR"
  end
end

describe "unzip post-processor" do
  it "extracts zip files" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR/zipdir"
    echo "test content" > "$ARCHIVE_TEST_DIR/zipdir/file.txt"
    cd "$ARCHIVE_TEST_DIR/zipdir" && zip test.zip file.txt && cd "$GHRI_DIR"
    cd "$ARCHIVE_TEST_DIR/zipdir"
    pp_unzip "test.zip"
    assert file_present "$ARCHIVE_TEST_DIR/zipdir/file.txt"
    cd "$GHRI_DIR"
  end

  it "updates CURRENT_ASSET variable" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR/zipdir"
    echo "test content" > "$ARCHIVE_TEST_DIR/zipdir/binary"
    cd "$ARCHIVE_TEST_DIR/zipdir" && zip archive.zip binary && cd "$GHRI_DIR"
    cd "$ARCHIVE_TEST_DIR/zipdir"
    pp_unzip "archive.zip"
    assert equal "$CURRENT_ASSET" "binary"
    cd "$GHRI_DIR"
  end
end

describe "find_single_match" do
  it "finds single matching file" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "content" > "$ARCHIVE_TEST_DIR/binary"
    cd "$ARCHIVE_TEST_DIR"
    local result
    result=$(find_single_match "binary")
    local rc=$?
    assert equal "$rc" "0"
    assert equal "$result" "binary"
  end

  it "fails when no matches found" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "content" > "$ARCHIVE_TEST_DIR/other"
    cd "$ARCHIVE_TEST_DIR"
    local result
    result=$(find_single_match "nonexistent")
    local rc=$?
    assert equal "$rc" "1"
  end

  it "fails when multiple matches found" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "content" > "$ARCHIVE_TEST_DIR/binary1"
    echo "content" > "$ARCHIVE_TEST_DIR/binary2"
    cd "$ARCHIVE_TEST_DIR"
    local result
    result=$(find_single_match "binary*")
    local rc=$?
    assert equal "$rc" "1"
  end

  it "matches an exact file name pattern" do
    cleanup_archive_test
    mkdir -p "$ARCHIVE_TEST_DIR"
    echo "content" > "$ARCHIVE_TEST_DIR/exact_name"
    cd "$ARCHIVE_TEST_DIR"
    local result
    result=$(find_single_match "exact_name")
    local rc=$?
    assert equal "$rc" "0"
    assert equal "$result" "exact_name"
  end
end