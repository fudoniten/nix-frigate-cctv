{
  description = "Frigate CCTV running in a container.";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = frigateContainer;
      frigateContainer = { ... }: {
        imports = [ arion.nixosModules.arion ./frigate-container.nix ];
      };
    };
  };
}
