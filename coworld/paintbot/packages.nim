import
  std/[json, sets, strutils, unicode],
  crunchy

type
  Archive {.importc: "struct archive", header: "<archive.h>", incompleteStruct.} = object
  Entry {.importc: "struct archive_entry", header: "<archive_entry.h>", incompleteStruct.} = object

const
  MaxSourceBytes* = 128 * 1024
  MaxModelBytes* = 16 * 1024 * 1024
  MaxManifestBytes* = 8192
  MaxPackageBytes* = MaxSourceBytes + MaxModelBytes + MaxManifestBytes + 4096

proc archiveReadNew(): ptr Archive {.importc: "archive_read_new", header: "<archive.h>".}
proc archiveReadSupportFormatZip(a: ptr Archive): cint {.importc: "archive_read_support_format_zip", header: "<archive.h>".}
proc archiveReadOpenMemory(a: ptr Archive, data: pointer, size: csize_t): cint {.importc: "archive_read_open_memory", header: "<archive.h>".}
proc archiveReadNextHeader(a: ptr Archive, entry: ptr ptr Entry): cint {.importc: "archive_read_next_header", header: "<archive.h>".}
proc archiveReadData(a: ptr Archive, data: pointer, size: csize_t): int {.importc: "archive_read_data", header: "<archive.h>".}
proc archiveReadFree(a: ptr Archive): cint {.importc: "archive_read_free", header: "<archive.h>".}
proc archiveEntryPathname(e: ptr Entry): cstring {.importc: "archive_entry_pathname", header: "<archive_entry.h>".}
proc archiveEntrySize(e: ptr Entry): int64 {.importc: "archive_entry_size", header: "<archive_entry.h>".}
proc archiveEntryIsEncrypted(e: ptr Entry): cint {.importc: "archive_entry_is_encrypted", header: "<archive_entry.h>".}

proc require(valid: bool, message: string) =
  ## Rejects an invalid policy before staging it for the engine.
  if not valid: raise newException(ValueError, message)

proc digest*(data: string): string =
  ## Returns the production manifest's lowercase SHA-256 representation.
  for value in sha256(data): result.add value.toHex(2).toLowerAscii()

proc checkSource*(data: string) =
  ## Applies the hosted BASIC source boundary.
  require(not data.startsWith("\0asm"), "WASM modules are not accepted")
  require(data.len <= MaxSourceBytes, "BASIC source exceeds 128 KiB")
  require(validateUtf8(data) == -1, "BASIC source is not UTF-8")

proc stagePolicy*(data, path: string): int =
  ## Streams bounded ZIP entries into fixed filenames beside the BASIC source.
  require(data.len <= MaxPackageBytes, "Policy exceeds package size limit")
  if not data.startsWith("PK\x03\x04"):
    checkSource(data)
    writeFile(path, data)
    return data.len
  let archive = archiveReadNew()
  require(archive != nil, "Cannot allocate ZIP reader")
  defer: discard archiveReadFree(archive)
  require(archiveReadSupportFormatZip(archive) == 0, "Cannot enable ZIP reader")
  require(archiveReadOpenMemory(archive, data.cstring, data.len.csize_t) == 0, "Invalid ZIP")
  var
    names: HashSet[string]
    source, model, manifestText: string
    entry: ptr Entry
  while true:
    let status = archiveReadNextHeader(archive, addr entry)
    if status == 1: break
    require(status == 0, "Invalid ZIP header")
    let name = $archiveEntryPathname(entry)
    require(name notin names, "Duplicate package entry")
    names.incl name
    let limit = case name
      of "policy.bas": MaxSourceBytes
      of "model.bin": MaxModelBytes
      of "manifest.json": MaxManifestBytes
      else: raise newException(ValueError, "Unexpected package entry")
    require(archiveEntryIsEncrypted(entry) == 0, "Encrypted package entry")
    let size = archiveEntrySize(entry)
    require(size >= 0 and size <= limit, "Oversized package entry")
    var payload = newString(limit + 1)
    var used = 0
    while used < payload.len:
      let count = archiveReadData(archive, addr payload[used], (payload.len - used).csize_t)
      require(count >= 0, "Corrupt package entry")
      if count == 0: break
      used += count
    require(used <= limit and used == size, "Invalid package entry size")
    payload.setLen(used)
    case name
    of "policy.bas": source = move(payload)
    of "model.bin": model = move(payload)
    else: manifestText = move(payload)
  require(names.len == 3, "Package requires manifest.json, policy.bas and model.bin")
  let manifest = parseJson(manifestText)
  require(manifest.kind == JObject and manifest{"schema"}.getStr in
    ["paintbot-neural-basic/1", "paintbot-neural-basic/2"], "Unsupported neural package schema")
  require(manifest{"sha256"} != nil and manifest{"sha256"}.kind == JObject, "Missing package hashes")
  require(manifest{"sha256", "policy.bas"}.getStr == digest(source) and
    manifest{"sha256", "model.bin"}.getStr == digest(model), "Package hash mismatch")
  for field in ["observation_contract", "action_contract"]:
    let hash = manifest{field}.getStr
    require(hash.len == 64 and hash.find(AllChars - {'0'..'9', 'a'..'f'}) < 0, "Invalid contract hash")
  checkSource(source)
  writeFile(path, source)
  writeFile(path & ".model.bin", model)
  writeFile(path & ".neural.json", manifestText)
  source.len
