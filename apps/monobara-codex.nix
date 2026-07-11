{ lib, pkgs, ... }:

let
  mkComposeApp = import ../modules/compose-app.nix { inherit lib pkgs; };
in

mkComposeApp {
  name = "monobara-codex";
  domain = "fullstack.typestrict.dev";
  repo = "Aszusz/monobara-codex";
  webPort = 8080;
  apiPort = 3000;
  images = {
    WEB_IMAGE = "ghcr.io/aszusz/monobara-codex-web";
    API_IMAGE = "ghcr.io/aszusz/monobara-codex-api";
  };
}
