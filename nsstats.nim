import std/[httpclient, json, strutils, strformat, parseopt, times, options]

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

proc getLastHourRange(): (string, string) =
  let now = getTime().utc
  let oneHourAgo = now - 1.hours
  let startTime = oneHourAgo.format("yyyy-MM-dd'T'HH:mm") & ":00"
  let endTime = now.format("yyyy-MM-dd'T'HH:mm") & ":00"
  return (startTime, endTime)

proc getLastDayRange(): (string, string) =
  let now = getTime().utc
  let oneDayAgo = now - 24.hours
  let startTime = oneDayAgo.format("yyyy-MM-dd'T'HH") & ":00:00"
  let endTime = now.format("yyyy-MM-dd'T'HH") & ":00:00"
  return (startTime, endTime)

proc main() =
  var isDay = false
  var p = initOptParser()

  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if key == "day" or key == "d":
        isDay = true
    else:
      discard

  const token = "a33e3882924ad719ca47db6ae18cabdb6dad5a4db75c602febb22eee50c0295b"
  let queryType = if isDay: "type=LastDay" else: ""

  let (startTime, endTime) =
    if isDay:
      getLastDayRange()
    else:
      getLastHourRange()

  let statsEndpoint =
    &"http://192.168.1.10:5380/api/dashboard/stats/get?{queryType}&token={token}"
  let settingsEndpoint = &"http://192.168.1.10:5380/api/settings/get?token={token}"
  let queryLogsEndpoint =
    &"http://192.168.1.10:5380/api/logs/query?name=Query%20Logs%20(Sqlite)" &
    &"&classPath=QueryLogsSqlite.App&start={startTime}Z&end={endTime}Z" &
    &"&responseType=Recursive&entriesPerPage=10000&descendingOrder=true&token={token}"

  let client = newHttpClient()

  try:
    let statsResp = parseJson(client.getContent(statsEndpoint)).to(StatsResponse)
    let settingsResp =
      parseJson(client.getContent(settingsEndpoint)).to(SettingsResponse)
    let queryLogsResp =
      parseJson(client.getContent(queryLogsEndpoint)).to(QueryLogsResponse)

    let stats = statsResp.response.stats
    let settings = settingsResp.response

    var totalRecursiveRtt = 0.0
    var rttValues: seq[float] = @[]
    for entry in queryLogsResp.response.entries:
      if entry.responseRtt.isSome():
        let rtt = entry.responseRtt.get()
        rttValues.add(rtt)
        totalRecursiveRtt += rtt

    let totalQueries = stats.totalCached + stats.totalRecursive
    let avgRecursiveRtt =
      if rttValues.len > 0:
        totalRecursiveRtt / float(rttValues.len)
      else:
        0.0

    let hitRate = calculatePercent(stats.totalCached, totalQueries)
    let missRate = 100.0 - hitRate
    let cachePopulation =
      calculatePercent(stats.cachedEntries, settings.cacheMaximumEntries)

    const labels = [
      "Total Queries", "Recursive Lookups", "Avg Recursive RTT", "Cached Responses",
      "Cache Population",
    ]

    var maxWidth = 0
    for l in labels:
      maxWidth = max(maxWidth, l.len + 1)

    echo align(labels[0], maxWidth), ": ", totalQueries

    stdout.write align(labels[1], maxWidth), ": ", stats.totalRecursive, " ("
    let missRateColor = colorGreenToRed(missRate)
    stdout.write missRateColor, &"{missRate:.1f}%\e[0m)\n"

    stdout.write align(labels[2], maxWidth), ": "
    if rttValues.len > 0:
      let color = colorGreenToRed(avgRecursiveRtt, 100.0)
      stdout.write color, &"{avgRecursiveRtt:.2f}ms\e[0m\n"
    else:
      echo "N/A"

    stdout.write align(labels[3], maxWidth), ": ", stats.totalCached, " ("
    let hitRateColor = colorRedToGreen(hitRate)
    stdout.write hitRateColor, &"{hitRate:.1f}%\e[0m)\n"

    stdout.write align(labels[4], maxWidth), ": "
    let cachePopColor = colorGreenToRed(cachePopulation)
    stdout.write cachePopColor, &"{cachePopulation:.1f}%\e[0m"
    echo &" ({stats.cachedEntries}/{settings.cacheMaximumEntries})"
  except CatchableError:
    echo "Error: ", getCurrentExceptionMsg()
  finally:
    client.close()

main()
