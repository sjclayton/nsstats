import
  std/[
    httpclient, json, strutils, strformat, parseopt, options, times, math, algorithm,
    os, net,
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

  QueryLogEntry = object
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
    host: string
    port: string
    token: string

func calculatePercent(part: int, total: int): float =
  if total > 0:
    return (float(part) / float(total)) * 100.0
  return 0.0

const GreenRgb = (166, 227, 161)
const YellowRgb = (249, 226, 175)
const RedRgb = (243, 139, 168)

func colorize(
    value: float, cap: float = 100.0, direction: ColorDirection = cdGreenRed
): string =
  let (fromRgb, toRgb, effectiveCap) =
    case direction
    of cdGreenRed:
      (GreenRgb, RedRgb, cap)
    of cdRedGreen:
      (RedRgb, GreenRgb, 100.0)

  let normalized = clamp(value / effectiveCap, 0.0, 1.0)
  let r = int(float(toRgb[0]) * normalized + float(fromRgb[0]) * (1.0 - normalized))
  let g = int(float(toRgb[1]) * normalized + float(fromRgb[1]) * (1.0 - normalized))
  let b = int(float(toRgb[2]) * normalized + float(fromRgb[2]) * (1.0 - normalized))
  return &"\e[38;2;{r};{g};{b}m"

func colorize(value: float, direction: ColorDirection): string =
  colorize(value, 100.0, direction)

func getHealthInfo(status: ResolverHealth): (string, string) =
  case status
  of rhOptimal:
    ("Optimal", &"\e[38;2;{GreenRgb[0]};{GreenRgb[1]};{GreenRgb[2]}m")
  of rhFair:
    ("Fair", &"\e[38;2;{YellowRgb[0]};{YellowRgb[1]};{YellowRgb[2]}m")
  of rhDegraded:
    ("Degraded", &"\e[38;2;{RedRgb[0]};{RedRgb[1]};{RedRgb[2]}m")
  of rhUnknown:
    ("N/A", "\e[0m")

func getConfigDir(): string =
  let xdgConfigHome = getEnv("XDG_CONFIG_HOME")
  if xdgConfigHome != "":
    result = xdgConfigHome / "nsstats"
  else:
    result = getHomeDir() / ".config" / "nsstats"

func getConfigPath(altConfig: string = ""): string =
  if altConfig != "":
    result = altConfig
  else:
    result = getConfigDir() / "config.toml"

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
host = "{config.host}"
port = "{config.port}"
token = "{config.token}"
"""
  writeFile(configPath, tomlContent)

proc createConfig(configPath: string): Config =
  echo "No configuration found"
  echo "Initializing new config file..."
  echo "Config file will be saved to: ", configPath
  echo ""

  # Get host
  var hostValid = false
  while not hostValid:
    stdout.write "Enter host (IP or FQDN): "
    let host = stdin.readLine().strip()
    if host == "":
      echo "Error: Host is required."
      continue
    if not isValidHost(host):
      echo "Error: Invalid host. Must be a valid IPv4 address or FQDN."
      continue
    result.host = host
    hostValid = true

  # Get port (optional)
  var portValid = false
  var port = ""
  while not portValid:
    stdout.write "Enter port (default = 5380): "
    port = stdin.readLine().strip()
    if port == "":
      result.port = "5380"
      portValid = true
    elif isValidPort(port):
      result.port = port
      portValid = true
    else:
      echo "Error: Port must be between 1-65535."

  # Get token
  var tokenValid = false
  while not tokenValid:
    stdout.write "Enter API token: "
    let token = stdin.readLine().strip()
    if token == "":
      echo "Error: API token is required."
      continue
    result.token = token
    tokenValid = true

  saveConfig(result, configPath)
  echo ""
  echo "Configuration saved successfully."
  echo ""

proc loadConfig(configPath: string): Config =
  let config = parsetoml.parseFile(configPath)
  let host = config["host"].getStr()
  let token = config["token"].getStr()

  if host == "":
    echo "Error: 'host' is required in config file: ", configPath
    quit(1)

  if not isValidHost(host):
    echo "Error: Invalid host in config file: ", host
    quit(1)

  if token == "":
    echo "Error: 'token' is required in config file: ", configPath
    quit(1)

  result.host = host
  result.token = token
  result.port =
    if config.hasKey("port"):
      let p = config["port"].getStr()
      if isValidPort(p):
        p
      else:
        echo "Error: Invalid port in config file: ", p
        quit(1)
    else:
      "5380"

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

proc fetchApi[T](client: HttpClient, url: string, label: string): T =
  let jsonNode = parseJson(client.getContent(url))

  let status = jsonNode["status"].getStr()
  let errorMsg =
    if jsonNode.hasKey("errorMessage"):
      some(jsonNode["errorMessage"].getStr())
    else:
      none(string)

  validateApiResponse(status, errorMsg, label)
  return jsonNode.to(T)

proc showHelp() =
  echo "Usage: nsstats [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -d, --daily    Show daily stats (last 24 hours)"
  echo "  -w, --weekly   Show weekly stats (last 7 days)"
  echo "  -c, --config   Use an alternate config file (-c /path/to/config.toml)"
  echo "  -h, --help     Show this help message"
  echo ""
  echo "If no option is provided, shows current (last hour) stats."
  echo ""
  echo "First run will prompt to create a config in $XDG_CONFIG_HOME/nsstats/config.toml, if one doesn't already exist."

proc main() =
  var isDaily = false
  var isWeekly = false
  var altConfig = ""
  var expectConfigValue = false
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

  let host = config.host
  let port = config.port
  let token = config.token

  let queryType =
    if isDaily:
      "type=LastDay&"
    elif isWeekly:
      "type=LastWeek&"
    else:
      ""

  let statsEndpoint =
    &"http://{host}:{port}/api/dashboard/stats/get?{queryType}token={token}"
  let settingsEndpoint = &"http://{host}:{port}/api/settings/get?token={token}"

  let client = newHttpClient()

  try:
    let stats =
      fetchApi[ApiResponse[StatsWrapper]](client, statsEndpoint, "stats").response.stats
    let settings =
      fetchApi[ApiResponse[Settings]](client, settingsEndpoint, "settings").response

    let now = getTime().utc
    var endTime = ""
    if isDaily:
      endTime = now.format("yyyy-MM-dd'T'HH") & ":00:00Z"
    elif isWeekly:
      endTime = now.format("yyyy-MM-dd'T'") & "00:00:00Z"
    else:
      endTime = now.format("yyyy-MM-dd'T'HH:mm") & ":00Z"

    let entriesBuffer = $(stats.totalRecursive + 1)

    let queryLogsEndpoint =
      &"http://{host}:{port}/api/logs/query?name=Query%20Logs%20(Sqlite)" &
      &"&classPath=QueryLogsSqlite.App&responseType=Recursive&end={endTime}" &
      &"&entriesPerPage={entriesBuffer}&descendingOrder=true&token={token}"

    let logs =
      fetchApi[ApiResponse[QueryLogsData]](client, queryLogsEndpoint, "logs").response

    var rttValues: seq[float] = @[]
    for entry in logs.entries:
      if entry.responseRtt.isSome():
        rttValues.add(entry.responseRtt.get())

    let hasRttValues = rttValues.len > 0

    let totalQueries = stats.totalCached + stats.totalRecursive
    let hitRate = calculatePercent(stats.totalCached, totalQueries)
    let missRate = 100.0 - hitRate
    let cachePopulation =
      calculatePercent(stats.cachedEntries, settings.cacheMaximumEntries)

    var medianRtt = 0.0
    var meanRtt = 0.0
    var p99Rtt = 0.0
    var stabilityPenalty = 0.0
    var healthStatus = rhUnknown
    var overallImpact = 0.0
    var dnsScore = 0.0

    if hasRttValues:
      rttValues.sort()
      let mid = rttValues.len div 2
      medianRtt =
        if rttValues.len mod 2 != 0:
          rttValues[mid]
        else:
          (rttValues[mid - 1] + rttValues[mid]) / 2.0

      var sumRtt = 0.0
      for v in rttValues:
        sumRtt += v
      meanRtt = sumRtt / float(rttValues.len)

      let p99Index = int(ceil(0.99 * float(rttValues.len))) - 1
      p99Rtt = rttValues[clamp(p99Index, 0, rttValues.len - 1)]

      stabilityPenalty = max(0.0, meanRtt - medianRtt)
      healthStatus =
        if stabilityPenalty < 10.0:
          rhOptimal
        elif stabilityPenalty < 20.0:
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

    const Labels = [
      "Total Queries", "Recursive Lookups", "Med/Avg/99% RTT", "Resolver Health",
      "Overall Impact", "Cached Responses", "Cache Population", "DNS Score",
    ]

    var maxWidth = 0
    for l in Labels:
      maxWidth = max(maxWidth, l.len + 2)

    let title =
      if isDaily:
        "Daily DNS Statistics "
      elif isWeekly:
        "Weekly DNS Statistics"
      else:
        "Hourly DNS Statistics"
    let headerWidth = 53
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

    stdout.write align(Labels[3], maxWidth), ": "
    let (healthLabel, healthColor) = getHealthInfo(healthStatus)
    stdout.write healthColor, healthLabel, "\e[0m\n"

    stdout.write align(Labels[4], maxWidth), ": "
    if hasRttValues:
      let impactColor = colorize(overallImpact, 20.0)
      stdout.write impactColor, &"{overallImpact:.2f}ms\e[0m (avg delay/lookup)\n"
    else:
      echo "N/A"

    stdout.write align(Labels[5], maxWidth),
      ": ", insertSep($stats.totalCached, ',', 3), " ("
    let hitRateColor = colorize(hitRate, cdRedGreen)
    stdout.write hitRateColor, &"{hitRate:.1f}%\e[0m)\n"

    stdout.write align(Labels[6], maxWidth), ": "
    let cachePopColor = colorize(cachePopulation)
    stdout.write &"{stats.cachedEntries}/{settings.cacheMaximumEntries} ("
    stdout.write cachePopColor, &"{cachePopulation:.1f}%\e[0m)\n\n"

    stdout.write align(Labels[7], maxWidth), ": "
    if hasRttValues:
      let scoreColor = colorize(dnsScore, cdRedGreen)
      stdout.write scoreColor, &"{int(round(dnsScore))}/100\e[0m\n"
    else:
      echo "N/A"
  except CatchableError:
    echo "Error: ", getCurrentExceptionMsg()
  finally:
    client.close()

main()
