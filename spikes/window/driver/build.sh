#!/bin/zsh
# Builds the throwaway Window-module driver against the package's Window + Engine sources.
set -e
cd "$(dirname "$0")"
ROOT=../../..
swiftc -swift-version 5 -O -o window-driver main.swift $ROOT/Sources/FinderSpeed/Window/*.swift $ROOT/Sources/FinderSpeed/Engine/*.swift
