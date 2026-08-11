{ config, lib, pkgs, ... }:

# HNVR sops-nix secrets module.
#
# Provides an opt-in wrapper around sops-nix for the HNVR leader +
# worker NixOS configs. Dev (devenv) does NOT enable this — it
# continues to use plaintext env vars (acceptable because the dev
# shell runs on Sergey's laptop with no real production data).
#
# The actual `sops-nix.nixosModules.sops` import is wired by the
# caller (mkLeaderVmModules / mkWorkerVmModules in flake.nix) — NixOS
# modules don't see flake inputs directly. This module declares only
# the HNVR-specific sops.secrets.* defaults + options, and the caller
# composes both modules in the host config.
#
# To activate on a production host:
#
#   1. Generate an age key on the host (or yubikey per sops-nix docs):
#        nix shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt
#      The resulting public key (age1...) goes into the .sops.yaml
#      creation_rules so newly-encrypted secrets are decryptable by
#      this host.
#
#   2. Copy nix/secrets-template.yaml to a path your host config can
#      see (e.g. ./secrets/leader.yaml), then fill in the plaintext
#      values and encrypt in-place:
#        sops --encrypt --in-place secrets/leader.yaml
#
#   3. In the host's NixOS config:
#        services.hnvr.secrets = {
#          enable = true;
#          sopsFile = ./secrets/leader.yaml;
#          ageKeyFile = "/var/lib/sops-nix/key.txt";
#        };
#
#   4. The leader systemd unit picks up the decrypted values via
#      EnvironmentFile automatically (see nix/module.nix).
#
# Rotation: edit the encrypted file with `sops secrets/leader.yaml`,
# change the value, redeploy. sops-nix rewrites the decrypted files
# on next boot/activation; systemd's EnvironmentFile picks up the
# new value on next service restart.
let
  cfg = config.services.hnvr.secrets;
in
{
  options.services.hnvr.secrets = {
    enable = lib.mkEnableOption "sops-nix secrets for HNVR leader/worker";

    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the sops-encrypted YAML file containing HNVR secrets.
        See nix/secrets-template.yaml for the expected key structure.
      '';
    };

    ageKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sops-nix/key.txt";
      description = ''
        Path to the host's age private key. sops-nix reads this at
        activation to decrypt the values from sopsFile. Generate via
        `nix shell nixpkgs#age -c age-keygen -o <path>`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # These options only exist if the caller has imported
    # sops-nix.nixosModules.sops alongside this module. The caller
    # (mkLeaderVmModules etc.) does so unconditionally.
    sops.defaultSopsFile = cfg.sopsFile;
    sops.age.keyFile = cfg.ageKeyFile;

    # Each entry maps to /run/secrets/<name> on the host. The leader
    # systemd unit (nix/module.nix) reads these via EnvironmentFile
    # (rebuilt from these single-value files into KEY=value fragments
    # in preStart).
    sops.secrets = {
      "hnvr-data-key" = {
        owner = "hnvr";
        # 32-byte base64 AES key for camera password_enc decryption.
      };
      "hnvr-s3-endpoint" = { owner = "hnvr"; };
      "hnvr-s3-access-key" = { owner = "hnvr"; };
      "hnvr-s3-secret-key" = { owner = "hnvr"; };
      "hnvr-s3-bucket" = { owner = "hnvr"; };
      "hnvr-db-url" = {
        owner = "hnvr";
        # postgresql://user:pass@host/dbname
      };
      "initial-admin-email" = { owner = "hnvr"; };
      "initial-admin-password" = { owner = "hnvr"; };
    };
  };
}
