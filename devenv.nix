{ pkgs, ... }:

let
  # Scratch, caches and temporary files resolve from the environment, so a
  # fresh clone on another host evaluates without local paths baked in.
  # NOTUI_SCRATCH_ROOT names a private root on a physical disk. A host setup
  # that exports HOST_SCRATCH_ROOT supplies the fallback. Never use NFS: Zig
  # 0.16 needs renameat2(RENAME_NOREPLACE) for its caches and d_type from
  # readdir for package unpacking, and NFS provides neither.
  scratchRoot =
    let
      v = builtins.getEnv "NOTUI_SCRATCH_ROOT";
      h = builtins.getEnv "HOST_SCRATCH_ROOT";
    in
    if v != "" then v
    else if h != "" then h + "/notui"
    else throw "Set NOTUI_SCRATCH_ROOT to a private scratch root on a physical disk";
  # Per-project cache roots: Zig flocks every global-cache manifest, and a
  # shared root can hold a dangling or foreign `p/`.
  zigGlobalCache = "${scratchRoot}/zig-global";
  zigLocalCache = "${scratchRoot}/zig-local";
  # Zig 0.16 always unpacks fetched packages into project-local zig-pkg/ and
  # has no setting to move it. On NFS, readdir returns DT_UNKNOWN and the
  # fetch fails with "illegal file type 'unknown'", so zig-pkg is a symlink
  # to this directory.
  zigPkg = "${scratchRoot}/zig-pkg";
in
rec {
  # zig 0.16 dev environment.
  # https://devenv.sh/basics/
  packages = with pkgs; [
    zig
    inetutils # hostname is required by zig-gate.
    util-linux # mountpoint is required by zig-gate.
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
        # Latin Modern text and math faces: the vendored ztex font tests
        # find them on disk, and the container has no /usr/share/fonts.
        pkgs.lmodern
        pkgs.lmmath
      ];
    };
    # devenv keeps the caller's TMPDIR, so only the Zig caches are set here.
    ZIG_GLOBAL_CACHE_DIR = zigGlobalCache;
    ZIG_LOCAL_CACHE_DIR = zigLocalCache;
  };

  enterShell = ''
    for d in "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR" "${zigPkg}"; do
      [ -d "$d" ] || (umask 077 && mkdir -p -- "$d")
    done
    # Re-point on every entry: the scratch disk is per host.
    pkg_link="$DEVENV_ROOT/zig-pkg"
    if [ -L "$pkg_link" ] || [ ! -e "$pkg_link" ]; then
      ln -sfn -- "${zigPkg}" "$pkg_link"
    else
      echo "notui: $pkg_link is a directory; remove it so it can link to ${zigPkg}" >&2
    fi
  '';

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  # Quality gates over every owned source (vendor/ is excluded through
  # GATE_EXCLUDE), then the render-pipeline benchmark.
  scripts.gate.exec = ''
    # Keep the user's own tools (zig-gate, zlint, zbc) reachable: some
    # container wrappers rebuild PATH and drop the user bin directory.
    # Appended, so the nix tools from `packages` stay in front.
    export PATH="$PATH:$HOME/.local/bin"
    zig-gate "$@" && zig build bench -Doptimize=ReleaseFast
  '';
}
