# Wrapper module that imports the unstable crowdsec module
# This allows the standard app_modules/default.nix import to work
{ ... }:
{
  imports = [
    ../_unstable/crowdsec
  ];
}
