{ lib, pkgs, ... }:

let
  mkComposeApp = import ../modules/compose-app.nix { inherit lib pkgs; };
in
mkComposeApp {
  name = "food-1";
  domain = "cookbook.typestrict.dev";
  repo = "Aszusz/food-1";
  webPort = 8081;
  apiPort = 3001;
  images = {
    WEB_IMAGE = "ghcr.io/aszusz/food-1-web";
    API_IMAGE = "ghcr.io/aszusz/food-1-api";
  };
}
