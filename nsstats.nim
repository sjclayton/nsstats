import
  std/[httpclient, json, strutils, strformat, parseopt, options, times, math, algorithm]

type
  CacheStats = object
    totalRecursive: int
    totalCached: int
    cachedEntries: int

  StatsWrapper = object
    stats: CacheStats

  StatsResponse = object
    status: string
    response: StatsWrapper
    errorMessage: Option[string]

  ConfigSettings = object
    cacheMaximumEntries: int

  SettingsResponse = object
    status: string
    response: ConfigSettings
    errorMessage: Option[string]

  QueryLogEntry = object
    responseRtt: Option[float]

  QueryLogsData = object
    entries: seq[QueryLogEntry]

  QueryLogsResponse = object
    status: string
    response: QueryLogsData
    errorMessage: Option[string]

  ResolverHealth = enum
    rhUnknown
    rhOptimal
    rhFair
    rhDegraded

func calculatePercent(part: int, total: int): float =
  if total > 0:
    return (float(part) / float(total)) * 100.0
  return 0.0

const greenRgb = (166, 227, 161)
const redRgb = (243, 139, 168)

func colorGreenToRed(value: float, cap: float = 100.0): string =
  let normalized = clamp(value / cap, 0.0, 1.0)
  let r = int(float(redRgb[0]) * normalized + float(greenRgb[0]) * (1.0 - normalized))
  let g = int(float(redRgb[1]) * normalized + float(greenRgb[1]) * (1.0 - normalized))
  let b = int(float(redRgb[2]) * normalized + float(greenRgb[2]) * (1.0 - normalized))
  return &"\e[38;2;{r};{g};{b}m"

func colorRedToGreen(value: float): string =
  let normalized = clamp(value / 100.0, 0.0, 1.0)
  let r = int(float(redRgb[0]) * (1.0 - normalized) + float(greenRgb[0]) * normalized)
  let g = int(float(redRgb[1]) * (1.0 - normalized) + float(greenRgb[1]) * normalized)
  let b = int(float(redRgb[2]) * (1.0 - normalized) + float(greenRgb[2]) * normalized)
  return &"\e[38;2;{r};{g};{b}m"

proc validateApiResponse(
    respStatus: string, respError: Option[string], apiName: string
) =
  case respStatus
  of "ok":
    return
  of "invalid-token":
    echo &"Error: {apiName} request failed: Invalid API token"
    quit(1)
  of "2fa-required":
    echo &"Error: 2FA required for {apiName} request (OTP not provided)"
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
  echo "  -h, --help     Show this help message"
  echo ""
  echo "If no option is provided, shows current (last hour) stats."

proc main() =
  var isDaily = false
  var isWeekly = false
  var p = initOptParser()

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "d", "daily":
        isDaily = true
      of "w", "weekly":
        isWeekly = true
      of "h", "help":
        showHelp()
        quit(0)
      else:
        echo "Invalid option: " & key
        echo ""
        showHelp()
        quit(1)
    of cmdArgument:
      echo "Unexpected argument: " & key
      echo ""
      showHelp()
      quit(1)
    of cmdEnd:
      discard

  const host = "192.168.1.10"
  const port = "5380"
  const token = "a33e3882924ad719ca47db6ae18cabdb6dad5a4db75c602febb22eee50c0295b"

  let queryType =
    if isDaily:
      "type=LastDay"
    elif isWeekly:
      "type=LastWeek"
    else:
      ""

  let statsEndpoint =
    &"http://{host}:{port}/api/dashboard/stats/get?{queryType}&token={token}"
  let settingsEndpoint = &"http://{host}:{port}/api/settings/get?token={token}"

  let client = newHttpClient()

  try:
    let stats = fetchApi[StatsResponse](client, statsEndpoint, "stats").response.stats
    let settings =
      fetchApi[SettingsResponse](client, settingsEndpoint, "settings").response

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

    let logs = fetchApi[QueryLogsResponse](client, queryLogsEndpoint, "logs").response

    var rttValues: seq[float] = @[]
    for entry in logs.entries:
      if entry.responseRtt.isSome():
        rttValues.add(entry.responseRtt.get())

    let totalQueries = stats.totalCached + stats.totalRecursive

    var medianRtt = 0.0
    var meanRtt = 0.0
    var p99Rtt = 0.0
    var stabilityPenalty = 0.0
    var healthStatus = rhUnknown
    var overallImpact = 0.0
    var dnsScore = 0.0

    if rttValues.len > 0:
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
        elif stabilityPenalty < 50.0:
          rhFair
        else:
          rhDegraded

      let recursiveWeight = float(stats.totalRecursive) / float(totalQueries)
      overallImpact = meanRtt * recursiveWeight

    let hitRate = calculatePercent(stats.totalCached, totalQueries)
    let missRate = 100.0 - hitRate
    let cachePopulation =
      calculatePercent(stats.cachedEntries, settings.cacheMaximumEntries)

    if rttValues.len > 0 and totalQueries > 0:
      let impactScore = 100.0 - clamp((overallImpact / 10.0) * 100.0, 0.0, 100.0)
      let cacheScore = hitRate
      let tailPenalty = clamp((p99Rtt / 500.0) * 100.0, 0.0, 100.0)
      let tailScore = 100.0 - tailPenalty

      dnsScore = (impactScore * 0.60) + (cacheScore * 0.30) + (tailScore * 0.10)
    else:
      dnsScore = 0.0

    const labels = [
      "Total Queries", "Recursive Lookups", "Med/Avg/99% RTT", "Resolver Health",
      "Overall Impact", "Cached Responses", "Cache Population", "DNS Score",
    ]

    var maxWidth = 0
    for l in labels:
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

    echo align(labels[0], maxWidth), ": ", totalQueries

    stdout.write align(labels[1], maxWidth), ": ", stats.totalRecursive, " ("
    let missRateColor = colorGreenToRed(missRate)
    stdout.write missRateColor, &"{missRate:.1f}%\e[0m)\n"

    stdout.write align(labels[2], maxWidth), ": "
    if rttValues.len > 0:
      let medColor = colorGreenToRed(medianRtt, 100.0)
      let meanColor = colorGreenToRed(meanRtt, 100.0)
      let p99Color = colorGreenToRed(p99Rtt, 300.0)

      stdout.write medColor, &"{medianRtt:.2f}ms\e[0m / "
      stdout.write meanColor, &"{meanRtt:.2f}ms\e[0m / "
      stdout.write p99Color, &"{p99Rtt:.2f}ms\e[0m\n"
    else:
      echo "N/A"

    let healthStr =
      case healthStatus
      of rhOptimal: "Optimal"
      of rhFair: "Fair"
      of rhDegraded: "Degraded"
      of rhUnknown: "N/A"

    stdout.write align(labels[3], maxWidth), ": "
    let healthColor =
      case healthStatus
      of rhOptimal:
        "\e[38;2;166;227;161m" # green
      of rhFair:
        "\e[38;2;249;226;175m" # yellow
      of rhDegraded:
        "\e[38;2;243;139;168m" # red
      of rhUnknown:
        "\e[0m"
    stdout.write healthColor, healthStr, "\e[0m\n"

    stdout.write align(labels[4], maxWidth), ": "
    let impactColor = colorGreenToRed(overallImpact, 10.0)
    stdout.write impactColor, &"{overallImpact:.2f}ms\e[0m (avg delay/query)\n"

    stdout.write align(labels[5], maxWidth), ": ", stats.totalCached, " ("
    let hitRateColor = colorRedToGreen(hitRate)
    stdout.write hitRateColor, &"{hitRate:.1f}%\e[0m)\n"

    stdout.write align(labels[6], maxWidth), ": "
    let cachePopColor = colorGreenToRed(cachePopulation)
    stdout.write &"{stats.cachedEntries}/{settings.cacheMaximumEntries} ("
    stdout.write cachePopColor, &"{cachePopulation:.1f}%\e[0m)\n\n"

    stdout.write align(labels[7], maxWidth), ": "
    if rttValues.len > 0 and totalQueries > 0:
      let scoreColor = colorRedToGreen(dnsScore)
      stdout.write scoreColor, &"{int(round(dnsScore))}/100\e[0m\n"
    else:
      echo "N/A"
  except CatchableError:
    echo "Error: ", getCurrentExceptionMsg()
  finally:
    client.close()

main()
