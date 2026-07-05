# frozen_string_literal: true

Sentry.capture_message("boot")
Honeybadger.notify("boot")
Rollbar.error("boot")
