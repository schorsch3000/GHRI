# Shell completion scripts (bash functional, fish functional if installed, zsh syntax)
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/fake_gh.sh"

# comp_world: a `ghri` command (wrapper around a copy of ghri.sh with a 3-package config) on PATH
comp_world() {
  rm -rf "$TEST_SANDBOX/cfg" "$TEST_SANDBOX/wbin"
  mkdir -p "$TEST_SANDBOX/wbin"
  fake_gh_setup
  fake_config 'packages:
  - slug: acme/one
  - slug: acme/two
    name: two
  - slug: acme/three'
  cp "$GHRI_DIR/ghri.sh" "$TEST_SANDBOX/cfg/ghri.sh"
  printf '#!/bin/bash\nexec bash "%s/cfg/ghri.sh" "$@"\n' "$TEST_SANDBOX" >"$TEST_SANDBOX/wbin/ghri"
  chmod +x "$TEST_SANDBOX/wbin/ghri"
  COMP_PATH="$TEST_SANDBOX/wbin:$FAKE_BIN_DIR:$PATH"
}

# bash_complete <words...>: run the bash completion for the command line "ghri <words>"; the last word is the one being completed
bash_complete() {
  local words=("ghri" "$@")
  PATH="$COMP_PATH" bash -c '
    source <(ghri completion bash)
    COMP_WORDS=("$@")
    COMP_CWORD=$(($# - 1))
    _ghri
    printf "%s\n" "${COMPREPLY[@]}"
  ' _ "${words[@]}" 2>&1
}

describe "ghri --names" do
  it "lists the configured package names" do
    comp_world
    assert equal "$(PATH="$COMP_PATH" ghri --names | tr '\n' ' ')" "one two three "
  end
end

describe "ghri completion" do
  it "prints a script for each supported shell" do
    comp_world
    local shell
    for shell in bash zsh fish; do
      assert_contains "$(PATH="$COMP_PATH" ghri completion $shell)" "ghri"
    done
  end

  it "rejects unknown shells and a missing shell" do
    comp_world
    PATH="$COMP_PATH" ghri completion csh >/dev/null 2>&1
    assert equal "$?" "2"
    PATH="$COMP_PATH" ghri completion >/dev/null 2>&1
    assert equal "$?" "2"
  end

  it "works without a config file" do
    mkdir -p "$TEST_SANDBOX/emptycfg"
    cp "$GHRI_DIR/ghri.sh" "$TEST_SANDBOX/emptycfg/ghri.sh"
    assert_contains "$(bash "$TEST_SANDBOX/emptycfg/ghri.sh" completion bash)" "_ghri"
  end
end

describe "bash completion" do
  it "is valid bash" do
    comp_world
    PATH="$COMP_PATH" ghri completion bash | bash -n
    assert equal "$?" "0"
  end

  it "completes the first word with commands and options" do
    comp_world
    local out
    out=$(bash_complete "")
    assert_contains "$out" "install"
    assert_contains "$out" "add"
    assert_contains "$out" "edit"
    assert_contains "$out" "delete"
    assert_contains "$out" "completion"
    assert_contains "$out" "--outdated"
  end

  it "narrows commands by prefix" do
    comp_world
    assert equal "$(bash_complete "in")" "install"
    assert equal "$(bash_complete "de")" "delete"
  end

  it "completes package names after install, edit, delete" do
    comp_world
    assert equal "$(bash_complete install "" | tr '\n' ' ')" "one two three "
    assert equal "$(bash_complete edit "t" | tr '\n' ' ')" "two three "
    assert equal "$(bash_complete delete "o" | tr '\n' ' ')" "one "
    assert equal "$(bash_complete rm "th")" "three"
  end

  it "completes options after a command" do
    comp_world
    assert_contains "$(bash_complete install --f)" "--force"
    assert_contains "$(bash_complete install one --q)" "--quiet"
  end

  it "completes shell names after completion" do
    comp_world
    assert equal "$(bash_complete completion "" | tr '\n' ' ')" "bash zsh fish "
    assert equal "$(bash_complete completion "f")" "fish"
  end

  it "offers nothing after add (a free-form owner/repo)" do
    comp_world
    assert equal "$(bash_complete add "")" ""
  end

  it "completes package names for --outdated" do
    comp_world
    assert equal "$(bash_complete --outdated "tw")" "two"
  end

  it "is registered for ghri and ghri.sh" do
    comp_world
    local out
    out=$(PATH="$COMP_PATH" bash -c 'source <(ghri completion bash); complete -p ghri ghri.sh')
    assert_contains "$out" "complete -F _ghri ghri"
    assert_contains "$out" "complete -F _ghri ghri.sh"
  end
end

describe "zsh completion" do
  it "is valid zsh" do
    if command -v zsh >/dev/null 2>&1; then
      comp_world
      PATH="$COMP_PATH" ghri completion zsh | zsh -n
      assert equal "$?" "0"
    else
      echo "    (skipped: zsh not installed)"
    fi
  end

  it "starts with #compdef for both command names" do
    comp_world
    assert equal "$(PATH="$COMP_PATH" ghri completion zsh | head -1)" "#compdef ghri ghri.sh"
  end
end

describe "fish completion" do
  it "is valid fish" do
    if command -v fish >/dev/null 2>&1; then
      comp_world
      PATH="$COMP_PATH" ghri completion fish | fish -n
      assert equal "$?" "0"
    else
      echo "    (skipped: fish not installed)"
    fi
  end

  it "completes commands and package names" do
    if command -v fish >/dev/null 2>&1; then
      comp_world
      local out
      out=$(PATH="$COMP_PATH" fish -c 'ghri completion fish | source; complete -C "ghri "; echo ---; complete -C "ghri --o"; echo ---; complete -C "ghri install t"; echo ---; complete -C "ghri completion "' 2>&1)
      assert_contains "$out" "install"
      assert_contains "$out" "completion"
      assert_contains "$out" "--outdated"
      assert_contains "$out" "two"
      assert_contains "$out" "three"
      assert_contains "$out" "zsh"
    else
      echo "    (skipped: fish not installed)"
    fi
  end
end

describe "completion of --no-cache" do
  it "is offered by bash completion" do
    comp_world
    assert_contains "$(bash_complete install --n)" "--no-cache"
    assert_contains "$(bash_complete install --r)" "--refresh"
  end
end
