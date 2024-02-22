{
  imports = [
    ../common.nix
    ./boot.nix
    ./disko.nix
    ./network.nix

    ../../modules/netboot-serve.nix
  ];

  networking = {
    hostName = "pluto";
    domain = "nixos.org";
    hostId = "e4c9bd10";
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "23.11";
}