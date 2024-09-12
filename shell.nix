{ pkgs ? import <nixpkgs> {} }:

pkgs.stdenv.mkDerivation {
  name = "Hugo Env";
  buildInputs = with pkgs; [
    hugo
  ];
}
