import std/os

## Points the build at the local Norx checkout and the prebuilt ORX libraries.
## Override the Norx location with the NORX_DIR environment variable.
let norxDir = getEnv("NORX_DIR", getHomeDir() / "tankfeud/norx")
let orxLibraryDir = normalizedPath(norxDir / "orx/code/lib/dynamic")

doAssert dirExists(normalizedPath(norxDir / "src")),
         "Norx sources not found at " & norxDir &
         " - set NORX_DIR to your Norx checkout"
doAssert fileExists(absolutePath(orxLibraryDir / "liborxd.so")),
         "ORX libraries not built in " & orxLibraryDir

switch("warning", "[LockLevel]:off")
switch("hints", "off")
switch("linedir", "on")
switch("debuginfo")
switch("stacktrace", "on")
switch("linetrace", "on")
switch("path", norxDir / "src")
switch("passL", "-L" & orxLibraryDir)

when defined(linux) or defined(macosx):
  switch("passL", "-Wl,-rpath," & orxLibraryDir)

when defined(release):
  switch("passL", "-lorx")
elif defined(profile):
  switch("passL", "-lorxp")
else:
  switch("passL", "-lorxd")
