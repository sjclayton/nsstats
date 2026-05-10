import
  std/[
    httpclient, json, strutils, strformat, parseopt, options, times, math, algorithm,
    os, net, asyncdispatch, tables, sequtils, locks,
  ],
  parsetoml

type
  Stats = object
    totalRecursive: int
    totalCached: int
    cachedEntries: int

  StatsWrapper = object
    stats: Stats

  Settings = object
    cacheMaximumEntries: int

  ResolverResult = object
    resolver: string
    ip: string
    protocol: string

  QueryLogEntry = object
    qname: string
    qtype: string
    responseRtt: Option[float]

  QueryLogsData = object
    entries: seq[QueryLogEntry]

  ApiResponse*[T] = object
    status: string
    errorMessage: Option[string]
    response: T

  ResolverHealth = enum
    rhUnknown
    rhOptimal
    rhFair
    rhDegraded

  ColorDirection = enum
    cdGreenRed
    cdRedGreen

  Config = object
    connMode: string
    host: string
    port: string
    token: string
    extraMetrics: bool

const
  GreenRgb = (166, 227, 161)
  YellowRgb = (249, 226, 175)
  RedRgb = (243, 139, 168)
  Labels = [
    "Total Queries", "Recursive Lookups", "Med/Avg/99% RTT", "Resolver Health",
    "Most Used Resolver", "Overall Impact", "Cached Responses", "Cache Population",
    "DNS Score",
  ]
  PrettyNamePatterns = [
    ("cloudflare", "Cloudflare"),
    ("google", "Google"),
    ("quad9", "Quad9"),
    ("opendns", "OpenDNS"),
    ("adguard", "AdGuard"),
    ("joindns4", "DNS4EU"),
  ]
  Version = staticExec("grep version *.nimble | cut -d'\"' -f2").strip()

func calculatePercent(part: int, total: int): float =
  if total > 0:
    return (float(part) / float(total)) * 100.0
  return 0.0

func rgbToAnsi(rgb: tuple): string =
  &"\e[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m"

func colorize(
    value: float, cap: float = 100.0, direction: ColorDirection = cdGreenRed
): string =
  let effectiveCap =
    case direction
    of cdGreenRed: cap
    of cdRedGreen: 100.0

  let t = clamp(value / effectiveCap, 0.0, 1.0)

  var r, g, b: int

  if direction == cdGreenRed:
    r = int(clamp(-178.0 * t * t + 255.0 * t + 166.0, 0.0, 255.0))
    g = int(clamp(-172.0 * t * t + 84.0 * t + 227.0, 0.0, 255.0))
    b = int(clamp(-42.0 * t * t + 49.0 * t + 161.0, 0.0, 255.0))
  else:
    r = int(clamp(-178.0 * t * t + 101.0 * t + 243.0, 0.0, 255.0))
    g = int(clamp(-172.0 * t * t + 260.0 * t + 139.0, 0.0, 255.0))
    b = int(clamp(-42.0 * t * t + 35.0 * t + 168.0, 0.0, 255.0))

  return &"\e[38;2;{r};{g};{b}m"

func colorize(value: float, direction: ColorDirection): string =
  colorize(value, 100.0, direction)

func getHealthStatus(status: ResolverHealth): (string, string) =
  case status
  of rhOptimal:
    ("Optimal", rgbToAnsi(GreenRgb))
  of rhFair:
    ("Fair", rgbToAnsi(YellowRgb))
  of rhDegraded:
    ("Degraded", rgbToAnsi(RedRgb))
  of rhUnknown:
    ("N/A", "\e[0m")

func getScoreRange(score: int): string =
  if score >= 75:
    rgbToAnsi(GreenRgb)
  elif score >= 50:
    rgbToAnsi(YellowRgb)
  else:
    rgbToAnsi(RedRgb)

func getPrettyName(resolver: string): string =
  let r = resolver.toLowerAscii()
  for (pattern, name) in PrettyNamePatterns:
    if r.contains(pattern):
      return name
  resolver

func getPrettyProto(protocol: string): string =
  let p = protocol.toLowerAscii()
  if p.contains("quic"):
    rgbToAnsi(GreenRgb) & "DoQ\e[0m"
  elif p.contains("https"):
    rgbToAnsi(GreenRgb) & "DoH\e[0m"
  elif p.contains("tls"):
    rgbToAnsi(YellowRgb) & "DoT\e[0m"
  else:
    rgbToAnsi(RedRgb) & protocol.toUpperAscii() & "\e[0m"

func getConfigPath(altConfig: string = ""): string =
  if altConfig != "":
    altConfig
  else:
    getConfigDir() / "nsstats" / "config.toml"

func isValidHost(host: string): bool =
  try:
    let ipAddr = parseIpAddress(host)
    if ipAddr.family == IpAddressFamily.IPv4:
      return true
  except:
    discard

  if host.contains('.'):
    for c in host:
      if not (c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_'}):
        return false
    return true

  return false

func isValidPort(portStr: string): bool =
  try:
    let portNum = parseInt(portStr)
    return portNum >= 1 and portNum <= 65535
  except:
    return false

proc saveConfig(config: Config, configPath: string) =
  let dir = parentDir(configPath)
  if dir != "" and not dirExists(dir):
    createDir(dir)

  let tomlContent = &"""
conn_mode = "{config.connMode}"
host = "{config.host}"
port = "{config.port}"
token = "{config.token}"
extra_metrics = {config.extraMetrics}
"""
  writeFile(configPath, tomlContent)

proc createConfig(configPath: string): Config =
  echo &"""No configuration found
Initializing new config file...
Config file will be saved to: {configPath}
"""

  # Get connection mode
  var connModeValid: bool
  while not connModeValid:
    stdout.write "Choose connection mode (0 = http (default), 1 = https): "
    let input = stdin.readLine().strip()
    let modeStr =
      case input
      of "", "0": "http"
      of "1": "https"
      else: ""
    if modeStr != "":
      result.connMode = modeStr
      connModeValid = true
    else:
      echo "Error: Invalid connection mode. Must be 0 (http) or 1 (https)."

  # Get host
  var hostValid: bool
  while not hostValid:
    stdout.write "Enter host (IP or FQDN): "
    let host = stdin.readLine().strip()
    if host == "":
      echo "Error: Host is required."
      continue
    if not isValidHost(host):
      echo "Error: Invalid host: Must be a valid IPv4 address or FQDN."
      continue
    result.host = host
    hostValid = true

  # Get port [optional]
  var portValid: bool
  var port: string
  let defaultPort = if result.connMode == "https": "53443" else: "5380"
  while not portValid:
    stdout.write &"Enter port (default = {defaultPort}): "
    port = stdin.readLine().strip()
    if port == "":
      result.port = defaultPort
      portValid = true
    elif isValidPort(port):
      result.port = port
      portValid = true
    else:
      echo "Error: Invalid port: Must be between 1-65535."

  # Get token
  var tokenValid: bool
  while not tokenValid:
    stdout.write "Enter API token: "
    let token = stdin.readLine().strip()
    if token == "":
      echo "Error: API token is required."
      continue
    result.token = token
    tokenValid = true

  # Extra metrics disabled by default
  result.extraMetrics = false

  saveConfig(result, configPath)
  echo ""
  echo "Configuration saved successfully."
  echo ""

proc loadConfig(configPath: string): Config =
  let config = parsetoml.parseFile(configPath)

  # Validate host/token
  if not config.hasKey("host"):
    echo "Error: 'host' is required in config file: ", configPath
    quit(1)
  if not config.hasKey("token"):
    echo "Error: 'token' is required in config file: ", configPath
    quit(1)

  let host = config["host"].getStr()
  let token = config["token"].getStr()

  if host == "":
    echo "Error: 'host' is empty in config file: ", configPath
    quit(1)
  if not isValidHost(host):
    echo "Error: Invalid host in config file: ", host
    quit(1)
  if token == "":
    echo "Error: 'token' is empty in config file: ", configPath
    quit(1)

  # Handle conn_mode (backwards compatibility)
  var connMode: string
  if config.hasKey("conn_mode"):
    let connModeStr = config["conn_mode"].getStr()
    if connModeStr notin ["http", "https"]:
      echo "Error: Invalid conn_mode in config file: ", connModeStr
      quit(1)
    connMode = connModeStr
  else:
    let existingConfig = readFile(configPath)
    let trimmedExisting =
      existingConfig.strip(leading = true, trailing = false, chars = {'\n', '\r'})
    let newConfig = "conn_mode = \"http\"\n" & trimmedExisting

    let tmpPath = configPath & ".tmp"
    try:
      writeFile(tmpPath, newConfig)
      moveFile(tmpPath, configPath)
    except CatchableError:
      if fileExists(tmpPath):
        removeFile(tmpPath)
      echo "Error: Failed to migrate existing config file: ", getCurrentExceptionMsg()
      quit(1)
    connMode = "http"

  result.connMode = connMode
  result.host = host
  result.port =
    if config.hasKey("port"):
      let port = config["port"].getStr()
      if isValidPort(port):
        port
      else:
        echo "Error: Invalid port in config file: ", port
        quit(1)
    else:
      if connMode == "https": "53443" else: "5380"
  result.token = token
  result.extraMetrics =
    if config.hasKey("extra_metrics"):
      config["extra_metrics"].getBool()
    else:
      false

var spinnerLock: Lock
var spinnerDone: bool

proc runSpinner() {.thread.} =
  let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var shown = false
  var i = 0
  while true:
    acquire(spinnerLock)
    if spinnerDone:
      release(spinnerLock)
      return
    release(spinnerLock)
    if not shown and (epochTime() - start) * 1000 >= 500:
      shown = true
    if shown:
      stdout.write("\r" & frames[i mod frames.len] & " Fetching data...")
      stdout.flushFile()
      inc i
    sleep(80)

proc getResolverInfo(
    client: AsyncHttpClient, endpointUrl: string, targetType: string
): Future[ResolverResult] {.async.} =
  try:
    let resp = await client.get(endpointUrl)
    let body = await resp.body
    let jsonNode = parseJson(body)
    if jsonNode["status"].getStr == "ok":
      let records = jsonNode["response"]["records"]
      for rec in records:
        if (rec["type"].getStr == targetType or records.len == 1) and
            rec.hasKey("responseMetadata"):
          let meta = rec["responseMetadata"]
          let rawName = meta["nameServer"].getStr
          let idx = rawName.find(" (")
          let name =
            if idx >= 0:
              rawName[0 ..< idx]
            else:
              rawName
          let ip =
            if idx >= 0:
              rawName[idx + 2 .. ^2].strip()
            else:
              "N/A"
          return
            ResolverResult(resolver: name, ip: ip, protocol: meta["protocol"].getStr)
  except:
    discard
  return ResolverResult(resolver: "Unknown", ip: "N/A", protocol: "N/A")

proc processClientQueries(
    client: AsyncHttpClient,
    queries: seq[tuple[name: string, qtype: string]],
    connMode, host, port, token: string,
): Future[Table[string, ResolverResult]] {.async.} =
  result = initTable[string, ResolverResult]()
  for q in queries:
    let url = &"{connMode}://{host}:{port}/api/cache/list?domain={q.name}&token={token}"
    let key = &"{q.name}|{q.qtype}"
    result[key] = await getResolverInfo(client, url, q.qtype)

proc validateApiResponse(
    respStatus: string, respError: Option[string], apiName: string
) =
  case respStatus
  of "ok":
    return
  of "invalid-token":
    echo &"Error: {apiName} request failed: Invalid API token"
    quit(1)
  of "error":
    let errMsg =
      if respError.isSome():
        respError.get()
      else:
        "No error message provided"
    echo &"Error: {apiName} request failed: {errMsg}"
    quit(1)
  else:
    echo &"Error: Unknown status '{respStatus}' from {apiName} request"
    quit(1)

proc fetchApi[T](client: HttpClient, endpointUrl: string, apiName: string): T =
  let jsonNode = parseJson(client.getContent(endpointUrl))

  let status = jsonNode["status"].getStr()
  let errorMsg =
    if jsonNode.hasKey("errorMessage"):
      some(jsonNode["errorMessage"].getStr())
    else:
      none(string)

  validateApiResponse(status, errorMsg, apiName)
  return jsonNode.to(T)

proc showHelp() =
  echo """
Usage: nsstats [OPTIONS]

Options:
  -d, --daily    Show daily stats (last 24 hours)
  -w, --weekly   Show weekly stats (last 7 days)
  -x, --extra    Show extra metrics (Resolver Health, Most Used Resolver)
  -c, --config   Use an alternate config file (-c /path/to/config.toml)
  -v, --version  Show current version
  -h, --help     Show this help message

If no option is provided, shows current (last hour) stats.

Extra metrics are disabled by default, enable them with extra_metrics = true in your config file, or
display them temporarily with -x/--extra.

First run will prompt to create a config in $XDG_CONFIG_HOME/nsstats/config.toml, if one doesn't already exist.
"""

proc main() =
  var isDaily: bool
  var isWeekly: bool
  var extraMetrics: bool
  var altConfig: string
  var expectConfigValue: bool
  var parser = initOptParser()

  for kind, key, val in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "d", "daily":
        isDaily = true
      of "w", "weekly":
        isWeekly = true
      of "c", "config":
        if val != "":
          altConfig = val
        else:
          expectConfigValue = true
      of "x", "extra":
        extraMetrics = true
      of "v", "version":
        echo &"nsstats v{Version}"
        quit(0)
      of "h", "help":
        showHelp()
        quit(0)
      else:
        echo "Invalid option: " & key
        echo ""
        showHelp()
        quit(1)
    of cmdArgument:
      if expectConfigValue:
        altConfig = key
        expectConfigValue = false
      else:
        echo "Unexpected argument: " & key
        echo ""
        showHelp()
        quit(1)
    of cmdEnd:
      discard

  if expectConfigValue:
    echo "Error: -c/--config requires a value"
    quit(1)

  let configPath = getConfigPath(altConfig)

  var config: Config
  if fileExists(configPath):
    config = loadConfig(configPath)
  else:
    if altConfig == "":
      config = createConfig(configPath)
    else:
      echo "Error: Config file not found: ", configPath
      quit(1)

  let connMode = config.connMode
  let host = config.host
  let port = config.port
  let token = config.token
  extraMetrics = extraMetrics or config.extraMetrics

  let queryType =
    if isDaily:
      "type=LastDay&"
    elif isWeekly:
      "type=LastWeek&"
    else:
      ""

  let statsEndpoint =
    &"{connMode}://{host}:{port}/api/dashboard/stats/get?{queryType}token={token}"
  let settingsEndpoint = &"{connMode}://{host}:{port}/api/settings/get?token={token}"

  let client = newHttpClient()

  initLock(spinnerLock)
  spinnerDone = false
  var spinnerThread: Thread[void]
  createThread(spinnerThread, runSpinner)

  try:
    let stats =
      fetchApi[ApiResponse[StatsWrapper]](client, statsEndpoint, "stats").response.stats
    let settings =
      fetchApi[ApiResponse[Settings]](client, settingsEndpoint, "settings").response

    let now = getTime().utc
    var endTime: string
    if isDaily:
      endTime = now.format("yyyy-MM-dd'T'HH") & ":00:00Z"
    elif isWeekly:
      endTime = now.format("yyyy-MM-dd'T'") & "00:00:00Z"
    else:
      endTime = now.format("yyyy-MM-dd'T'HH:mm") & ":00Z"

    let entriesBuffer = $(stats.totalRecursive + 1)

    let queryLogsEndpoint =
      &"{connMode}://{host}:{port}/api/logs/query?name=Query%20Logs%20(Sqlite)" &
      &"&classPath=QueryLogsSqlite.App&responseType=Recursive&end={endTime}" &
      &"&entriesPerPage={entriesBuffer}&descendingOrder=true&token={token}"

    let logs =
      fetchApi[ApiResponse[QueryLogsData]](client, queryLogsEndpoint, "logs").response

    var rttValues: seq[float]
    for entry in logs.entries:
      if entry.responseRtt.isSome():
        rttValues.add(entry.responseRtt.get())

    assert(
      rttValues.len <= parseInt(entriesBuffer),
      &"entriesBuffer overflow: got: {rttValues.len} values, want: <={entriesBuffer}",
    )
    let hasRttValues = rttValues.len > 0

    var resolverCounts = initCountTable[string]()

    if extraMetrics:
      var uniqueQueries: seq[tuple[name: string, qtype: string]]

      for entry in logs.entries:
        if entry.responseRtt.isSome():
          let pair = (name: entry.qname, qtype: entry.qtype)
          if pair notin uniqueQueries:
            uniqueQueries.add(pair)

      var lookupMap = initTable[string, ResolverResult]()

      if hasRttValues:
        const NumClients = 20
        let clients = newSeqWith(NumClients, newAsyncHttpClient())
        var clientQueries = newSeq[seq[tuple[name: string, qtype: string]]](NumClients)

        for i, q in uniqueQueries:
          clientQueries[i mod NumClients].add(q)

        var clientFuts: seq[Future[Table[string, ResolverResult]]]
        for i in 0 ..< NumClients:
          if clientQueries[i].len > 0:
            clientFuts.add processClientQueries(
              clients[i], clientQueries[i], connMode, host, port, token
            )

        let allTables = waitFor all(clientFuts)
        for t in allTables:
          for key, val in t:
            lookupMap[key] = val

        for c in clients:
          c.close()

        for entry in logs.entries:
          if entry.responseRtt.isSome():
            let key = &"{entry.qname}|{entry.qtype}"
            if lookupMap.hasKey(key) and lookupMap[key].resolver != "Unknown":
              let res = lookupMap[key]
              resolverCounts.inc(&"{res.resolver}|{res.ip}|{res.protocol}")

      resolverCounts.sort()

    let totalQueries = stats.totalCached + stats.totalRecursive
    let hitRate = calculatePercent(stats.totalCached, totalQueries)
    let missRate = 100.0 - hitRate
    let cachePopulation =
      calculatePercent(stats.cachedEntries, settings.cacheMaximumEntries)

    var medianRtt: float
    var meanRtt: float
    var p99Rtt: float
    var stabilityPenalty: float
    var healthStatus = rhUnknown
    var overallImpact: float
    var dnsScore: float

    if hasRttValues:
      rttValues.sort()
      let mid = rttValues.len div 2
      medianRtt =
        if rttValues.len mod 2 != 0:
          rttValues[mid]
        else:
          (rttValues[mid - 1] + rttValues[mid]) / 2.0

      var sumRtt: float
      for v in rttValues:
        sumRtt += v
      meanRtt = sumRtt / float(rttValues.len)

      let p99Index = int(ceil(0.99 * float(rttValues.len))) - 1
      p99Rtt = rttValues[clamp(p99Index, 0, rttValues.len - 1)]

      if extraMetrics:
        stabilityPenalty = max(0.0, meanRtt - medianRtt)
        healthStatus =
          if stabilityPenalty < 15.0:
            rhOptimal
          elif stabilityPenalty < 25.0:
            rhFair
          else:
            rhDegraded

      let recursiveWeight = float(stats.totalRecursive) / float(totalQueries)
      overallImpact = meanRtt * recursiveWeight

      let impactScore = 100.0 - clamp((overallImpact / 20.0) * 100.0, 0.0, 100.0)
      let cacheScore = hitRate
      let tailScore = 100.0 - clamp((p99Rtt / 500.0) * 100.0, 0.0, 100.0)
      let populationScore =
        if cachePopulation >= 90.0:
          100.0 - cachePopulation
        else:
          100.0

      dnsScore =
        (impactScore * 0.40) + (cacheScore * 0.35) + (tailScore * 0.15) +
        (populationScore * 0.10)

    acquire(spinnerLock)
    spinnerDone = true
    release(spinnerLock)

    var maxWidth: int
    for l in Labels:
      maxWidth = max(maxWidth, l.len + 2)

    let title =
      if isDaily:
        "Daily DNS Statistics "
      elif isWeekly:
        "Weekly DNS Statistics"
      else:
        "Hourly DNS Statistics"
    let headerWidth = 55
    stdout.write("\e[2K\r")
    echo center(title, headerWidth)
    echo repeat("-", headerWidth)

    echo align(Labels[0], maxWidth), ": ", insertSep($totalQueries, ',', 3)

    stdout.write align(Labels[1], maxWidth),
      ": ", insertSep($stats.totalRecursive, ',', 3), " ("
    let missRateColor = colorize(missRate)
    stdout.write missRateColor, &"{missRate:.1f}%\e[0m)\n"

    stdout.write align(Labels[2], maxWidth), ": "
    if hasRttValues:
      let medColor = colorize(medianRtt, 100.0)
      let meanColor = colorize(meanRtt, 100.0)
      let p99Color = colorize(p99Rtt, 300.0)

      stdout.write medColor, &"{medianRtt:.2f}ms\e[0m / "
      stdout.write meanColor, &"{meanRtt:.2f}ms\e[0m / "
      stdout.write p99Color, &"{p99Rtt:.2f}ms\e[0m\n"
    else:
      echo "N/A"

    if extraMetrics:
      stdout.write align(Labels[3], maxWidth), ": "
      let (healthLabel, healthColor) = getHealthStatus(healthStatus)
      stdout.write healthColor, healthLabel, "\e[0m\n"

      if resolverCounts.len > 0:
        let (topResolver, _) = resolverCounts.largest()
        let sep = topResolver.split("|")
        var resolver = sep[0]
        let ip =
          if sep.len > 1:
            sep[1]
          else:
            "N/A"
        var proto =
          if sep.len > 2:
            sep[2]
          else:
            "N/A"
        resolver = getPrettyName(resolver)
        proto = getPrettyProto(proto)
        stdout.write align(Labels[4], maxWidth), ": "
        stdout.write &"{resolver} ({ip}) via {proto}", "\n"

    stdout.write align(Labels[5], maxWidth), ": "
    if hasRttValues:
      let impactColor = colorize(overallImpact, 20.0)
      stdout.write impactColor, &"{overallImpact:.2f}ms\e[0m (avg delay/lookup)\n"
    else:
      echo "N/A"

    stdout.write align(Labels[6], maxWidth),
      ": ", insertSep($stats.totalCached, ',', 3), " ("
    let hitRateColor = colorize(hitRate, cdRedGreen)
    stdout.write hitRateColor, &"{hitRate:.1f}%\e[0m)\n"

    stdout.write align(Labels[7], maxWidth), ": "
    let cachePopColor = colorize(cachePopulation)
    stdout.write &"{stats.cachedEntries}/{settings.cacheMaximumEntries} ("
    stdout.write cachePopColor, &"{cachePopulation:.1f}%\e[0m)\n\n"

    stdout.write align(Labels[8], maxWidth), ": "
    if hasRttValues:
      let score = int(round(dnsScore))
      let scoreColor = getScoreRange(score)
      stdout.write scoreColor, &"{score}/100\e[0m\n"
    else:
      echo "N/A"
  except CatchableError:
    acquire(spinnerLock)
    spinnerDone = true
    release(spinnerLock)
    stdout.write("\e[2K\r")
    echo "Error: ", getCurrentExceptionMsg()
  finally:
    acquire(spinnerLock)
    spinnerDone = true
    release(spinnerLock)
    client.close()

main()
