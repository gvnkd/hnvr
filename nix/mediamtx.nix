{ config, lib, pkgs, ... }:

# MediaMTX sidecar — RTSP → WebRTC (WHEP) bridge for live view.
#
# Leader-only. Reads /run/hnvr/mediamtx.yml which is rendered by the
# leader's MediaMTXConfigSyncer (Phase 2 Slice 2). Both run as the
# hnvr system user so they can share /run/hnvr (created via tmpfiles).
#
# NOTE: nixpkgs pins mediamtx 1.18.2 (verified Aug 10 2026); the design
# locks v1.20.0 for WHEP browser compat. The version doesn't matter for
# packaging — bump via overlay (buildGoModule from v1.20.0 tarball) if
# Slice 3 verification fails on Chrome 130+. The roadmap decision point
# at Phase 2 kickoff is the trigger for that.
let
  cfg = config.services.hnvr.mediamtx;

  # Minimal stub the leader will overwrite on first sync. Avoids
  # chicken-and-egg between mediamtx.service and hnvr-leader.service
  # at boot: mediamtx can come up before ConfigSyncer has rendered
  # anything, then SIGHUP/REST picks up the real config later.
  stubConfig = pkgs.writeText "mediamtx-stub.yml" ''
    api: yes
    apiAddress: :${toString cfg.apiPort}
    hls: no
    moq: no
    webrtc: yes
    webrtcAddress: :${toString cfg.webrtcPort}
    webrtcEncryption: no
    webrtcAllowOrigins: ['*']
    rtsp: yes
    rtspAddress: :${toString cfg.rtspPort}
  '';
in
{
  options.services.hnvr.mediamtx = {
    enable = lib.mkEnableOption "MediaMTX (RTSP->WebRTC WHEP) — leader only";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mediamtx;
      defaultText = "pkgs.mediamtx";
      description = ''
        mediamtx derivation. nixpkgs pins v1.18.2; design locks v1.20.0.
        Bump via overlay if Slice 3 WHEP verification fails on Chrome 130+.
      '';
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 9997;
      description = "MediaMTX REST API port. ConfigSyncer uses /v2/config/* endpoints.";
    };

    webrtcPort = lib.mkOption {
      type = lib.types.port;
      default = 8889;
      description = "WebRTC (WHEP/WHIP) HTTP port. /whep/<slug> reverse-proxies here.";
    };

    rtspPort = lib.mkOption {
      type = lib.types.port;
      default = 8554;
      description = ''
        RTSP *server* port. CaptureWorker pulls from
        rtsp://localhost:<rtspPort>/<slug> instead of from the camera
        directly so mediamtx becomes the single ingestion point
        (1 RTSP session per camera regardless of how many consumers —
        required for cameras with a 1-concurrent-session cap).
        Default :8554 avoids the :554 conflict with the cameras themselves.
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.path;
      default = "/run/hnvr/mediamtx.yml";
      description = "Where the leader writes the generated mediamtx.yml. ConfigSyncer owns the file.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "hnvr";
      description = "User to run mediamtx as. Shares the hnvr system user so it can read /run/hnvr/mediamtx.yml.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "hnvr";
      description = "Group to run mediamtx as.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.optionals config.networking.firewall.enable
      [ cfg.apiPort cfg.webrtcPort cfg.rtspPort ];

    # Shared runtime directory — owned by hnvr so both hnvr-leader
    # (ConfigSyncer writes the YAML) and mediamtx (reads it) can access.
    # tmpfiles creates it on boot; systemd's per-service RuntimeDirectory=
    # would be isolated to one service.
    systemd.tmpfiles.rules = [
      "d /run/hnvr 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.mediamtx = {
      description = "MediaMTX (RTSP->WebRTC WHEP) — leader only";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        if [ ! -f ${cfg.configPath} ]; then
          cp ${stubConfig} ${cfg.configPath}
          chmod 0600 ${cfg.configPath}
        fi
      '';

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/mediamtx ${cfg.configPath}";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening (loosened in Phase 6 for GPU/CV access if needed).
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = [ "/run/hnvr" ];
      };
    };
  };
}
