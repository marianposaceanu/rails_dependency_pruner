# Rails version support

The gem currently targets Rails `8.x` apps on Ruby `>= 3.2`.

## supported now

| surface | status |
| --- | --- |
| Ruby | gemspec allows `>= 3.2`; local production-readiness work uses Ruby `4.0.5` |
| Rails | gemspec allows `>= 8.0`, `< 9.0` |
| catalogs | versioned catalogs exist for Rails `8.0` and `8.1` |
| platform | local benchmark evidence is Darwin arm64 |
| large app benchmark | Lobsters copy under `tmp/lobsters-ruby405-rails813` |
| small app target | `generic_blog_app`, generic blog app |

## app shapes covered by static fixtures

The checked-in fixture matrix covers planner decisions for:

- minimal controller and Active Record model
- Active Record only
- Action Mailer
- Active Storage attachment declarations
- Active Job
- Action Text
- Action Cable channel and mount
- mounted Rack or engine route
- Sentry, Honeybadger, Rollbar, and Rack Mini Profiler integration signals
- third-party integration policy classes for `sentry-rails`, `sentry-ruby`,
  `honeybadger`, `rollbar`, and `rack-mini-profiler`
- native-heavy direct-use signals for `ruby-vips` and `nokogiri`

These fixtures are static source shapes, not bootable apps. Planner matrix
fixtures assert keep/prune decisions; doctor fixtures assert app capability
signals. Lobsters and `generic_blog_app` remain the real RSS benchmark targets.

## not production-supported yet

- Rails `7.2` catalogs
- Linux x86_64 and Linux arm64 release measurements
- Puma clustered, Falcon, and Passenger matrices
- Bootable Action Text and third-party observability sample apps beyond static fixtures

Production approval is still app-specific. A supported Rails version only means
the catalog and gem dependency range exist; approval still requires coverage,
runtime evidence, measurement gates, reviewed rollback, and a rollout patch.
