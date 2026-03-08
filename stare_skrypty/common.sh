#!/usr/bin/env bash
IFS=$'\n\t'
info(){ printf "\e[1;34m[INFO]\e[0m %s\n" "$*"; }
ok(){   printf "\e[1;32m[ OK ]\e[0m %s\n" "$*"; }
warn(){ printf "\e[1;33m[WARN]\e[0m %s\n" "$*"; }
err(){  printf "\e[1;31m[ERR ]\e[0m %s\n" "$*"; }
