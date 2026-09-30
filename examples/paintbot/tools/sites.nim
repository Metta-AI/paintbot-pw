import
  std/[base64, json, os, strutils],
  tournaments

const
  DefaultSite* = Root.parentDir / "polyworld-buff"
  SiteUrl = "https://metta-ai.github.io/polyworld-buff/"
  Assets* = [
    ("regular", "fonts/Rubik-Regular.ttf"),
    ("bold", "fonts/Rubik-Bold.ttf"),
    ("logo", "paint-crew.png"), ("victory", "icons/victory.png"),
    ("chalice", "icons/chalice.png"), ("champion", "icons/champion.png"),
    ("stats", "icons/stats.png"), ("day", "icons/day.png")
  ]

proc assetPath*(dataRoot, path: string): string =
  ## Finds Paintbot's checked-in artwork and the shared original game assets.
  if path == "paint-crew.png":
    return SourceDirectory / "assets" / path
  dataRoot / path

proc validateSite*(siteRoot: string) =
  ## Requires the existing Paintbot guide before publishing alongside it.
  if siteRoot.len > 0:
    require(fileExists(siteRoot / "Paintbot/index.html"),
      "Missing Paintbot guide: " & siteRoot)

proc navigation*(): string =
  ## Keeps the report connected to the Paintbot guide and Polyworld home.
  "<header class=\"site-header wrap\"><img src=\"@@logo@@\" " &
    "alt=\"Paint Crew\"><div><a class=site-brand href=\"" & SiteUrl &
    "\">Polyworld Buff</a><nav aria-label=\"Paintbot pages\">" &
    "<a href=\"" & SiteUrl & "Paintbot/\">Paintbot guide</a>" &
    "<a href=\"" & SiteUrl & "Paintbot/standings/\" " &
    "aria-current=page>Tournament standings</a></nav></div></header>"

proc updateSite*(html: string, summary: JsonNode, dataRoot, siteRoot: string,
    controls = Controls()) =
  ## Copies assets and publishes the latest report plus its dated archive.
  if siteRoot.len == 0:
    return
  validateSite(siteRoot)
  var page = html
  for (_, path) in Assets:
    let
      bytes = readFile(assetPath(dataRoot, path))
      mime = if path.endsWith(".ttf"): "font/ttf" else: "image/png"
      embedded = "data:" & mime & ";base64," & encode(bytes)
      destination = siteRoot / "Paintbot/assets" / path
    require(embedded in page, "Missing embedded report asset: " & path)
    page = page.replace(embedded, "../assets/" & path)
    if not fileExists(destination) or readFile(destination) != bytes:
      saveBytes(destination, bytes, controls)
  for path in ["fonts/OFL-Rubik.txt", "icons/license.md"]:
    let source = dataRoot / path
    if fileExists(source):
      let destination = siteRoot / "Paintbot/assets" / path
      if not fileExists(destination) or readFile(destination) != readFile(source):
        saveBytes(destination, readFile(source), controls)
  page = page.replace("href=\"" & SiteUrl & "Paintbot/standings/\"",
    "href=\"./\"")
  page = page.replace("href=\"" & SiteUrl & "Paintbot/\"", "href=\"../\"")
  page = page.replace("href=\"" & SiteUrl & "\"", "href=\"../../\"")
  let
    destination = siteRoot / "Paintbot/standings"
    name = summary["run"].getStr
  require(name.len > 0 and name.allCharsInSet(
    Letters + Digits + {'_', '-', '.'}) and name notin [".", ".."],
    "Invalid archive name")
  saveBytes(destination / "index.html", page, controls)
  saveBytes(destination / (name & ".html"), page, controls)
  let guidePath = siteRoot / "Paintbot/index.html"
  var guide = readFile(guidePath)
  if "href=\"standings/\"" notin guide:
    let marker = "<a class=\"jump\" href=\"#overview\">Learn the game &darr;</a>"
    require(marker in guide, "Cannot find Paintbot guide navigation")
    guide = guide.replace(marker, marker &
      " <a class=\"jump\" href=\"standings/\">Tournament standings &rarr;</a>")
    saveBytes(guidePath, guide, controls)
