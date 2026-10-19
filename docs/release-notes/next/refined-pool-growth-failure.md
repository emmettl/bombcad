kind: fixed

**A refined run that runs out of memory while its pools grow carries on as it was.** When the
first level of twice-refined air could not grow its pool for want of memory, it had already moved
its share of the shared buffers, and the second level was left in the old ones, its cells read from
the wrong place. Growth now changes nothing until every buffer it needs has been made, so a run
short of memory keeps its pools and refines no more than they hold, as intended. Runs whose pools
grow are unchanged.
