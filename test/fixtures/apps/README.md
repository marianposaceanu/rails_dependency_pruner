# reference app fixtures

Small static Rails app shapes used by the regression matrix. They are not
bootable apps; they give the planner stable source evidence for framework
keep/prune decisions.

Covered shapes include minimal Rails, Active Record only, Action Mailer, Action
Mailbox, Active Storage attachments, Active Job, Action Text, Action Cable,
mounted engines, eager-load and boot-cache modes, config-only adapter settings,
observability integrations, and direct native-heavy gem usage such as
`ruby-vips` and `nokogiri`.
