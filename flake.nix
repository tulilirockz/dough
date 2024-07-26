{  
  description = "Declarative Disk Management";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let      
      supportedSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
      forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import nixpkgs { inherit system; };
      });
    in {
      formatter = forEachSupportedSystem ({pkgs}: pkgs.nixfmt-rfc-style);      
      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            glibc
            util-linux.dev
            util-linux
          ];
          C_INCLUDE_PATH = "${pkgs.util-linux.dev}/include";
          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [pkgs.stdenv.cc.cc pkgs.util-linux]}";
          packages = with pkgs; [
            zig
            meson
            flex
            bison
            autoconf
            gettext
            libtool
            automake
          ];
        };
      });
    };
}
