import std/[httpclient, json, strutils, strformat, parseopt, options, math, algorithm]

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

  ConfigSettings = object
    cacheMaximumEntries: int

  SettingsResponse = object
    status: string
    response: ConfigSettings

  QueryLogEntry = object
    responseRtt: Option[float]

  QueryLogsData = object
    entries: seq[QueryLogEntry]

  QueryLogsResponse = object
    status: string
    response: QueryLogsData

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

proc main() =
  var isDay = false
  var p = initOptParser()

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "d", "day":
        isDay = true
      else:
        quit("Invalid option: " & key, 1)
    of cmdArgument:
      quit("Unexpected argument: " & key, 1)
    of cmdEnd:
      discard

  const host = "192.168.1.10"
  const port = "5380"
  const token = "a33e3882924ad719ca47db6ae18cabdb6dad5a4db75c602febb22eee50c0295b"

  let queryType = if isDay: "type=LastDay" else: ""

  let statsEndpoint =
    &"http://{host}:{port}/api/dashboard/stats/get?{queryType}&token={token}"
  let settingsEndpoint = &"http://{host}:{port}/api/settings/get?token={token}"

  let client = newHttpClient()

  try:
    let statsResp = parseJson(client.getContent(statsEndpoint)).to(StatsResponse)
    let stats = statsResp.response.stats

    let entriesBuffer = $(stats.totalRecursive + 1)

    let queryLogsEndpoint =
      &"http://{host}:{port}/api/logs/query?name=Query%20Logs%20(Sqlite)" &
      &"&classPath=QueryLogsSqlite.App&responseType=Recursive" &
      &"&entriesPerPage={entriesBuffer}&descendingOrder=true&token={token}"

    let settingsResp =
      parseJson(client.getContent(settingsEndpoint)).to(SettingsResponse)
    let queryLogsResp =
      parseJson(client.getContent(queryLogsEndpoint)).to(QueryLogsResponse)

    let settings = settingsResp.response

    var rttValues: seq[float] = @[]
    for entry in queryLogsResp.response.entries:
      if entry.responseRtt.isSome():
        rttValues.add(entry.responseRtt.get())

    var medianRtt = 0.0
    var stdDev = 0.0
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
      let meanRtt = sumRtt / float(rttValues.len)

      var sumSqDiff = 0.0
      for v in rttValues:
        sumSqDiff += pow(v - meanRtt, 2)
      stdDev = sqrt(sumSqDiff / float(rttValues.len))

    let totalQueries = stats.totalCached + stats.totalRecursive
    let hitRate = calculatePercent(stats.totalCached, totalQueries)
    let missRate = 100.0 - hitRate
    let cachePopulation =
      calculatePercent(stats.cachedEntries, settings.cacheMaximumEntries)

    const labels = [
      "Total Queries", "Recursive Lookups", "Avg/Std Recursive RTT", "Cached Responses",
      "Cache Population",
    ]

    var maxWidth = 0
    for l in labels:
      maxWidth = max(maxWidth, l.len + 2)

    let title = if isDay: "Daily DNS Statistics " else: "Hourly DNS Statistics"
    let headerWidth = 47
    echo center(title, headerWidth)
    echo repeat("-", headerWidth)

    echo align(labels[0], maxWidth), ": ", totalQueries

    stdout.write align(labels[1], maxWidth), ": ", stats.totalRecursive, " ("
    let missRateColor = colorGreenToRed(missRate)
    stdout.write missRateColor, &"{missRate:.1f}%\e[0m)\n"

    stdout.write align(labels[2], maxWidth), ": "
    if rttValues.len > 0:
      let avgColor = colorGreenToRed(medianRtt, 100.0)
      let stdColor = colorGreenToRed(stdDev, 30.0)
      stdout.write avgColor, &"{medianRtt:.2f}ms\e[0m / "
      stdout.write stdColor, &"±{stdDev:.2f}ms\e[0m\n"
    else:
      echo "N/A"

    stdout.write align(labels[3], maxWidth), ": ", stats.totalCached, " ("
    let hitRateColor = colorRedToGreen(hitRate)
    stdout.write hitRateColor, &"{hitRate:.1f}%\e[0m)\n"

    stdout.write align(labels[4], maxWidth), ": "
    let cachePopColor = colorGreenToRed(cachePopulation)
    stdout.write &"{stats.cachedEntries}/{settings.cacheMaximumEntries} ("
    stdout.write cachePopColor, &"{cachePopulation:.1f}%\e[0m)\n"
  except CatchableError:
    echo "Error: ", getCurrentExceptionMsg()
  finally:
    client.close()

main()
