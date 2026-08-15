## Screenshot helper. Adapted from tankfeud's utils.nim.
import os
import times
import norx

proc findLatestScreenshot(directory: string): string =
  ## Returns the most recently created PNG file name in `directory`.
  if not dirExists(directory):
    return ""
  var
    latestTime: Time
    first = true
  for file in walkFiles(directory / "*.png"):
    let info = getFileInfo(file, followSymlink = true)
    if first or info.lastWriteTime > latestTime:
      latestTime = info.lastWriteTime
      result = extractFilename(file)
      first = false

proc takeScreenshot*(): string =
  ## Captures a screenshot and returns the path of the written file.
  createDir("screenshots")
  if capture().isFailure:
    echo "Failed to take a screenshot"
    return ""
  let filename = findLatestScreenshot("screenshots")
  if filename == "":
    echo "Screenshot captured but the file was not found"
    return ""
  result = "screenshots" / filename
  echo "Screenshot: ", result
