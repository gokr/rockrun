# Package

version       = "1.0.0"
author        = "Göran Krampe"
description   = "Rockrun - a physics-based Boulder Dash successor built with the Norx wrapper for the ORX game engine"
license       = "MIT"
srcDir        = "src"
installDirs   = @["data"]
bin           = @["rockrun"]

# Dependencies

requires "nim >= 2.2.4"
requires "norx >= 0.8.1"

task check, "Compile-check every Rockrun source file":
  exec "nim check src/rockrun.nim"

task test, "Run the scripted in-engine startup test suite":
  # NOTE: ORX resolves the main ini from the executable name, so the test
  # binary must be called `rockrun` (it's gitignored).
  exec "nim c -o:rockrun src/rockrun.nim && ./rockrun -c test.ini --startup-test true"

task release, "Build a release binary against the optimized ORX library":
  exec "nim c -d:release -o:rockrun src/rockrun.nim"
