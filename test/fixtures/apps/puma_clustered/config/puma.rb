# frozen_string_literal: true

workers 2
threads 3, 5
preload_app!
plugin :tmp_restart
