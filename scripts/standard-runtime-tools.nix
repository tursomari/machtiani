# Producer-only packaging. No compiler or Nix installation on the target.
{ pkgs }:
{
  # The upstream portable binary avoids rewriting Go's writable dynamic
  # segment into a read-only ELF load segment. Keep the publisher's checksum.
  # https://github.com/git-lfs/git-lfs/releases/tag/v3.7.1
  git-lfs = pkgs.stdenvNoCC.mkDerivation {
    pname = "git-lfs-portable";
    version = "3.7.1";
    src = pkgs.fetchurl {
      url = "https://github.com/git-lfs/git-lfs/releases/download/v3.7.1/git-lfs-linux-amd64-v3.7.1.tar.gz";
      sha256 = "1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08";
    };
    dontConfigure = true;
    dontBuild = true;
    dontPatchELF = true;
    dontStrip = true;
    installPhase = ''
      mkdir -p "$out/bin" "$out/share/licenses/git-lfs"
      cp git-lfs "$out/bin/git-lfs"
      cp CHANGELOG.md README.md "$out/share/licenses/git-lfs/"
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
}
