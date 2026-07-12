# examples/nix-build-box/flake.nix — the smallest flake that proves the box works.
#
# Inside the running box (see README.md / MANUAL_TESTING.md):
#   nix build   .#hello   && ./result/bin/hello   # → "Hello, world!"
#   nix develop .#default  -c which git            # → a /nix/store/... path
#   nix flake   metadata                           # → resolves the pinned input
#
# It pins nixpkgs to a *released channel* so the evaluation is reproducible; bump
# the ref (or pin a flake.lock) when you want a newer nixpkgs. This is deliberately
# NOT the systemd-261 image flake — that lives in the measured-boot lab and pins a
# systemd 261 overlay. This one just answers "is Nix working in here at all?".
{
  description = "nix-build-box smoke flake — proves flakes + nix-command work";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # `nix build .#hello` — the classic "did the build system work" derivation.
      # Both attrs live in ONE `packages.${system}` set: Nix forbids defining the
      # same dynamic attribute (`${system}`) twice across separate statements.
      packages.${system} = {
        hello = pkgs.hello;
        default = pkgs.hello;
      };

      # `nix develop` — an ephemeral dev shell, the other half of a build box.
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.git pkgs.jq pkgs.coreutils ];
        shellHook = ''echo "nix-build-box devShell ready: $(nix --version)"'';
      };
    };
}
