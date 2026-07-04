# transform registry

Production profiles include a `transforms` list. It names every boot mutation
the profile asks the runtime to apply.

The existing schema remains v2 for now. The registry is a production-readiness
layer on top of the current fields, not a new profile format yet.

## current transform ids

Framework and boot-plan transforms:

- `disable_framework:<framework>`
- `prune_railtie:<path>`
- `ignore_autoload_path:<path>`
- `ignore_eager_load_path:<path>`

Extreme boot transforms:

- `disable_eager_load`
- `skip_railtie:<path>`
- `lazy_require:<path>`
- `lazy_gem:<name>`
- `stub:rack_mini_profiler`
- `stub:active_storage_vips_analyzer`

## production rules

Production verification fails when a profile has a boot mutation without a
matching transform id. It also fails when the transform list contains an
unknown id.

`lazy_gem:<name>` is registered only when the gem has a policy in
`TransformRegistry::LAZY_GEM_POLICIES`. Unknown lazy gems stay out of
production approval.

`stub:active_storage_vips_analyzer` is high risk. It is allowed only when the
app has no Active Storage attachment DSL usage or when the coverage manifest
proves attachment analysis behavior. The stub makes the Active Storage Vips
analyzer decline instead of loading `ruby-vips` during boot. Direct app use of
`Vips` can still lazy-load `ruby-vips`.

## why this exists

The old profile shape could say `lazy_gems: ["ruby-vips"]`, but that hid two
different changes:

- defer the `ruby-vips` gem until direct `Vips` use;
- change Active Storage analyzer selection during boot.

The transform registry makes those changes separate and reviewable. It also
gives later work a stable place for event manifests, ablation results, and
coverage requirements.
