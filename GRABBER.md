# Grabber

`SiteGrabber` fetches HTML, extracts `href`/`src`, and keeps URLs that match selected resource types.

Safety:

- max depth 5
- max URLs 2000 (default 200)
- delay between requests
- robots.txt Disallow for `User-agent: *`
- scope: page / directory / domain
- cancel flag
- http(s) only
