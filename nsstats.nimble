# Package
version = "0.3.0"
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
task debug, "Build debug binary":
  exec "nim c -d:ssl --outdir:" & binDir & " --out:" & binDir & "/nsstats nsstats.nim"
task release, "Build release binary":
  exec "nim c -d:release -d:strip -d:ssl --opt:size --panics:on --outdir:" & binDir &
    " --out:" & binDir & "/nsstats nsstats.nim"
