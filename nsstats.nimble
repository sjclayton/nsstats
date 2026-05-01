# Package
version = "0.1.0"
author = "Shaun J. Clayton"
description = "Simple statistics tool for Technitium DNS Server"
license = "MIT"

srcDir = "."
bin = @["nsstats"]
binDir = "bin"

# Dependencies
requires "nim >= 2.2.10"
requires "parsetoml >= 0.7.2"

# Tasks
task release, "Build release binary":
  exec "nim c -d:release -d:strip --opt:size --panics:on --outdir:" & binDir & " --out:" &
    binDir & "/nsstats nsstats.nim"
