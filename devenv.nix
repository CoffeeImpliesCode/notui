{ pkgs, ... }:

rec {
  # zig 0.16 dev environment (house convention, cf. ~/projects/wayland).
  # https://devenv.sh/basics/
  packages = with pkgs; [
    zig
    bash
    pkg-config
    zig-zlint
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  scripts.gate.exec = "zig-gate";
}
