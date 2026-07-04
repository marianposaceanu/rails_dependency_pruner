# profile schema

Generated deterministic profiles use schema v3.

Schema v3 keeps the old v2 sections for compatibility, but adds production
readiness fields:

- `tool`: gem name, gem version, and optional build git sha
- `environment`: Ruby, Rails, Bundler, platform, Rails env, and Bundler groups
- `fingerprints`: material input digests
- `transforms`: registered boot mutations
- `expected_events`: events expected from registered transforms

The profile id is stored in both `profile_id` and
`fingerprints.profile_id` while v2 compatibility remains. The digest ignores
both id fields.

## fingerprints

Production validation compares the current app against the profile. These
inputs are material:

- `Gemfile`
- `Gemfile.lock`
- `.bundle/config`
- `config/application.rb`
- `config/boot.rb`
- `config/environment.rb`
- `config/environments/*.rb`
- `config/initializers/**/*.rb`
- `config/routes.rb`
- `config/routes/**/*.rb`
- `app/**/*.rb`
- `lib/**/*.rb`
- `engines/*/app/**/*.rb`
- `engines/*/config/**/*.rb`
- the coverage manifest
- runtime evidence files

Files under `tmp`, `vendor/bundle`, and `node_modules` are ignored.

## migration

`ProfileSchema.migrate_v2` can project a v2 payload into the v3 shape for
review or tooling. It is not used to silently approve old profiles as new
profiles; v2 profiles remain readable and validated through the legacy fields.
