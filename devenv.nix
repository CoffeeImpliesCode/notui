{ pkgs, ... }:

{
  # zig 0.16 dev environment.
  # https://devenv.sh/basics/
  packages = with pkgs; [
    zig
    bash
    pkg-config
    zig-zlint
    # Terminal screenshots and recordings.
    vhs
    termshot
    charm-freeze
    ttyd
    ffmpeg
    # emscripten
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
    # Vendored packages have separate quality gates. Check every owned source.
    GATE_EXCLUDE = "^./vendor/";
    FONTCONFIG_FILE = pkgs.makeFontsConf {
      fontDirectories = [
        pkgs.dejavu_fonts
        pkgs.noto-fonts-cjk-sans
        pkgs.noto-fonts-color-emoji
      ];
    };
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  # Quality gates over every owned source (vendor/ is excluded through
  # GATE_EXCLUDE), then the render-pipeline benchmark.
  scripts.gate.exec = ''
    # Keep the user's own tools (zig-gate, zlint, zbc) reachable: some
    # container wrappers rebuild PATH and drop the user bin directory.
    # Appended, so the nix tools from `packages` stay in front.
    export PATH="$PATH:$HOME/.local/bin"
    # Zig's local cache must stay off NFS: renameat2(RENAME_NOREPLACE)
    # returns EINVAL there and aborts the build runner. The untracked
    # .envrc holds that override.
    if [ -f .envrc ]; then . ./.envrc; fi

    zig-gate "$@" && zig build bench -Doptimize=ReleaseFast
  '';
}
